# GuzPay — Full Code Spec (MVP)

This spec defines a demo-ready **remittance MVP** named **GuzPay** with a **.NET 8 Web API** backend and a **Flutter** mobile app (iOS/Android). It’s tuned for **Visual Studio + GitHub Copilot** and a Windows development environment. The UX is modern, colorful, and intuitive, with smooth animations and a diaspora-first flow.

---

## 1) Architecture Overview

- **Backend**: .NET 8 Web API (C#), Entity Framework Core + **SQLite** (demo), BackgroundService for settlement, simple bearer/JWT stub, CORS open for local dev.
- **Mobile**: Flutter 3 (Dart 3), Riverpod (hooks_riverpod), GoRouter, Dio, Freezed/JsonSerializable, Lottie, Google Fonts, dark/light themes, EN/AM localization.
- **Agent-friendly**: Repository structure and clear contracts so Copilot (or any agent) can generate features incrementally.

**End-to-end user flow**
1) Login (email + OTP stub)
2) Add Beneficiary
3) Request Quote (5‑minute FX lock)
4) Submit Transfer (2FA)
5) Watch **pending → settled** automatically (~15s)
6) See Transfers & share receipt

---

## 2) API Contract (OpenAPI-lite)

### Auth
- `POST /auth/login`
  - Body: `{ "email": "demo@guzpay.com", "otp": "123456" }`
  - 200: `{ "token": "…" }`

### Beneficiaries
- `POST /beneficiaries` → 201 `{ id, name, phone, payoutMethod, accountNumber, bankCode }`
- `GET /beneficiaries` → 200 `[{...}]`
- `PUT /beneficiaries/{id}` → 200 `{...}`
- `DELETE /beneficiaries/{id}` → 204

### Quote
- `POST /quote`
  - Body: `{ "amount": 100, "beneficiaryId": "…" }`
  - 200: `{ "quoteId": "…", "fx_rate": 57.25, "fee": 1.5, "receive_amount": 5673.5, "expires_at": "ISO-8601" }`

### Transfer
- `POST /transfer` (headers: `Idempotency-Key: …`)
  - Body: `{ "quoteId": "…", "twofa": "123456" }`
  - 202: `{ "transferId": "…", "status": "pending", "eta": "~15 minutes" }`
- `GET /transfers` → 200 `[{ id, status, createdAt, ... }]`
- `GET /transfers/{id}` → 200 `{ id, status, ... }`

**Notes**
- Use bearer auth header `Authorization: Bearer <token>` after `/auth/login`.
- Keep numbers as decimals in backend; handle JSON (double) on client.

---

## 3) Data Model (EF Core)

**User**  
`Id (Guid), Email (string), CreatedAt (DateTime)`

**Beneficiary**  
`Id, UserId (FK), Name, Phone, PayoutMethod (enum: bank, telebirr, hellocash), AccountNumber, BankCode, CreatedAt`

**Quote**  
`Id, UserId, BeneficiaryId, SourceCurrency ("USD"), TargetCurrency ("ETB"), Amount (decimal), FxRate (decimal), Fee (decimal), ReceiveAmount (decimal), ExpiresAt (DateTime), CreatedAt`

**Transfer**  
`Id, UserId, QuoteId, Status (enum: pending, settled, aml_hold, failed), Eta (string), CreatedAt, SettledAt (nullable)`

**AuditEvent**  
`Id, UserId, EventType (string), PayloadJson (string), CreatedAt`

---

## 4) Backend (.NET 8) — Project Structure

```
GuzPay.sln
src/
  GuzPay.Api/
    Program.cs
    appsettings.json
    Controllers/
      AuthController.cs
      BeneficiariesController.cs
      QuoteController.cs
      TransferController.cs
    Data/
      AppDbContext.cs
      Seed.cs
    Domain/
      Entities/*.cs
      Enums/*.cs
    Services/
      QuoteService.cs
      TransferService.cs
      SettlementWorker.cs
    Utils/
      JwtStub.cs
      IdempotencyStore.cs
tests/
  GuzPay.Api.Tests/
    QuoteTests.cs
```

### `Program.cs` (Minimal API wiring with Controllers)
```csharp
using GuzPay.Api.Data;
using GuzPay.Api.Services;
using GuzPay.Api.Utils;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer().AddSwaggerGen();
builder.Services.AddDbContext<AppDbContext>(o => o.UseSqlite("Data Source=app.db"));
builder.Services.AddHostedService<SettlementWorker>();
builder.Services.AddScoped<QuoteService>();
builder.Services.AddScoped<TransferService>();
builder.Services.AddSingleton<IdempotencyStore>();
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .AllowAnyHeader().AllowAnyMethod().AllowAnyOrigin()));

var app = builder.Build();
app.UseSwagger().UseSwaggerUI();
app.UseCors();
app.MapControllers();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    db.Database.EnsureCreated();
    Seed.Apply(db);
}
app.Run();
```

### `AppDbContext.cs` (EF Core)
```csharp
using GuzPay.Api.Domain.Entities;
using Microsoft.EntityFrameworkCore;

namespace GuzPay.Api.Data
{
    public class AppDbContext : DbContext
    {
        public DbSet<User> Users => Set<User>();
        public DbSet<Beneficiary> Beneficiaries => Set<Beneficiary>();
        public DbSet<Quote> Quotes => Set<Quote>();
        public DbSet<Transfer> Transfers => Set<Transfer>();
        public DbSet<AuditEvent> AuditEvents => Set<AuditEvent>();
        public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) {}
    }
}
```

### Entities (example: `Quote.cs`)
```csharp
namespace GuzPay.Api.Domain.Entities
{
    public class Quote
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public Guid UserId { get; set; }
        public Guid BeneficiaryId { get; set; }
        public string SourceCurrency { get; set; } = "USD";
        public string TargetCurrency { get; set; } = "ETB";
        public decimal Amount { get; set; }
        public decimal FxRate { get; set; }
        public decimal Fee { get; set; }
        public decimal ReceiveAmount { get; set; }
        public DateTime ExpiresAt { get; set; }
        public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    }
}
```

### `QuoteService.cs` (fee math + expiry)
```csharp
using GuzPay.Api.Data;
using GuzPay.Api.Domain.Entities;
using System.Text.Json;

namespace GuzPay.Api.Services
{
    public class QuoteService
    {
        private readonly AppDbContext _db;
        private const decimal FX = 57.25m;
        private const decimal FEE_RATE = 0.012m; // 1.2%

        public QuoteService(AppDbContext db){ _db = db; }

        public Quote Create(Guid userId, Guid beneficiaryId, decimal amount)
        {
            var fee = Math.Max(1.5m, amount * FEE_RATE);
            var receive = (amount - fee) * FX;
            var q = new Quote {
                UserId = userId, BeneficiaryId = beneficiaryId, Amount = amount,
                FxRate = FX, Fee = Math.Round(fee, 2), ReceiveAmount = Math.Round(receive,2),
                ExpiresAt = DateTime.UtcNow.AddMinutes(5)
            };
            _db.Quotes.Add(q);
            _db.AuditEvents.Add(new AuditEvent { UserId = userId, EventType = "QUOTE_CREATED",
                PayloadJson = JsonSerializer.Serialize(new { q.Id, amount })});
            _db.SaveChanges();
            return q;
        }
    }
}
```

### `SettlementWorker.cs` (flip pending → settled)
```csharp
using GuzPay.Api.Data;
using Microsoft.EntityFrameworkCore;

namespace GuzPay.Api.Services
{
    public class SettlementWorker : BackgroundService
    {
        private readonly IServiceScopeFactory _scopeFactory;
        public SettlementWorker(IServiceScopeFactory f){ _scopeFactory = f; }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            while(!stoppingToken.IsCancellationRequested)
            {
                using var scope = _scopeFactory.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
                var pendings = await db.Transfers
                    .Where(t => t.Status == "pending" && t.CreatedAt < DateTime.UtcNow.AddSeconds(-15))
                    .ToListAsync(stoppingToken);
                foreach (var t in pendings) {
                    t.Status = "settled";
                    t.SettledAt = DateTime.UtcNow;
                    db.AuditEvents.Add(new AuditEvent { UserId = t.UserId, EventType = "TRANSFER_SETTLED",
                        PayloadJson = System.Text.Json.JsonSerializer.Serialize(new { t.Id })});
                }
                if (pendings.Count > 0) await db.SaveChangesAsync(stoppingToken);
                await Task.Delay(3000, stoppingToken);
            }
        }
    }
}
```

### Controllers (example: `QuoteController.cs`)
```csharp
using GuzPay.Api.Data;
using GuzPay.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace GuzPay.Api.Controllers
{
    [ApiController]
    [Route("quote")]
    public class QuoteController : ControllerBase
    {
        private readonly QuoteService _svc;
        private readonly AppDbContext _db;
        public QuoteController(QuoteService svc, AppDbContext db){ _svc = svc; _db = db; }

        public record QuoteRequest(decimal Amount, Guid BeneficiaryId);

        [HttpPost]
        public IActionResult Create([FromBody] QuoteRequest req)
        {
            var user = _db.Users.First(); // demo: single user
            var q = _svc.Create(user.Id, req.BeneficiaryId, req.Amount);
            return Ok(new {
                quoteId = q.Id, fx_rate = q.FxRate, fee = q.Fee,
                receive_amount = q.ReceiveAmount, expires_at = q.ExpiresAt
            });
        }
    }
}
```

*(Add controllers for Auth, Beneficiaries, Transfers; include a simple login returning a token and a fixed OTP `123456`.)*

### `Seed.cs`
```csharp
using GuzPay.Api.Domain.Entities;

namespace GuzPay.Api.Data
{
    public static class Seed
    {
        public static void Apply(AppDbContext db)
        {
            if (!db.Users.Any()){
                var u = new User { Email = "demo@guzpay.com" };
                db.Users.Add(u);
                db.Beneficiaries.AddRange(
                    new Beneficiary { UserId = u.Id, Name="Meron H.", Phone="+2519...", PayoutMethod="telebirr", AccountNumber="", BankCode="" },
                    new Beneficiary { UserId = u.Id, Name="Kidist L.", Phone="+2519...", PayoutMethod="bank", AccountNumber="123456789", BankCode="ZEMEN" }
                );
                db.SaveChanges();
            }
        }
    }
}
```

---

## 5) Flutter App — Project Structure (GuzPay)

```
guzpay_app/
  lib/
    core/ (theme, colors, fonts, utils)
    data/ (models, dtos, repositories, api_client.dart)
    features/
      onboarding/
      auth/
      home/
      beneficiaries/
      send/
      transfers/
      settings/
    routing/app_router.dart
    localization/
      l10n_en.arb
      l10n_am.arb
    main.dart
  pubspec.yaml
```

### `pubspec.yaml` (key deps)
```yaml
name: guzpay_app
description: GuzPay mobile app (Flutter remittance MVP)
environment:
  sdk: ">=3.0.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
  hooks_riverpod: ^2.5.1
  go_router: ^14.2.7
  dio: ^5.6.0
  freezed_annotation: ^2.4.4
  json_annotation: ^4.9.0
  google_fonts: ^6.2.1
  lottie: ^3.1.2
  intl: ^0.19.0
  flutter_localizations:
    sdk: flutter
dev_dependencies:
  build_runner: ^2.4.11
  freezed: ^2.5.7
  json_serializable: ^6.8.0
  flutter_lints: ^4.0.0
  flutter_test:
    sdk: flutter
```

### `lib/main.dart` (init + router)
```dart
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'routing/app_router.dart';
import 'core/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GuzPayApp());
}

class GuzPayApp extends StatelessWidget {
  const GuzPayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: 'GuzPay',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        routerConfig: appRouter,
      ),
    );
  }
}
```

### `lib/routing/app_router.dart`
```dart
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/auth/auth_screen.dart';
import '../features/home/home_screen.dart';
import '../features/beneficiaries/beneficiaries_screen.dart';
import '../features/send/amount_screen.dart';
import '../features/send/review_screen.dart';
import '../features/send/success_screen.dart';
import '../features/transfers/transfers_screen.dart';
import '../features/settings/settings_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/onboarding',
  routes: [
    GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
    GoRoute(path: '/auth', builder: (_, __) => const AuthScreen()),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/beneficiaries', builder: (_, __) => const BeneficiariesScreen()),
    GoRoute(path: '/send/amount', builder: (_, __) => const AmountScreen()),
    GoRoute(path: '/send/review', builder: (_, __) => const ReviewScreen()),
    GoRoute(path: '/send/success', builder: (_, __) => const SuccessScreen()),
    GoRoute(path: '/transfers', builder: (_, __) => const TransfersScreen()),
    GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
  ],
);
```

### `lib/data/api_client.dart` (Dio client)
```dart
import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ApiClient {
  final Dio _dio = Dio(BaseOptions(
    baseUrl: const String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:5000'),
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body, {Map<String, String>? headers}) async {
    final res = await _dio.post(path, data: body, options: Options(headers: headers));
    return res.data as Map<String, dynamic>;
  }

  Future<List<dynamic>> getList(String path) async {
    final res = await _dio.get(path);
    return res.data as List<dynamic>;
  }
}

final apiClientProvider = Provider((_) => ApiClient());
```

### `lib/features/send/presentation/review_screen.dart` (countdown demo)
```dart
import 'dart:async';
import 'package:flutter/material.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});
  @override State<ReviewScreen> createState() => _ReviewState();
}

class _ReviewState extends State<ReviewScreen> {
  late DateTime expiresAt;
  late Timer t;
  Duration remaining = Duration.zero;

  @override void initState(){
    super.initState();
    // For demo: 5 min from now. Replace with quote.expiresAt from provider.
    expiresAt = DateTime.now().add(const Duration(minutes: 5));
    t = Timer.periodic(const Duration(seconds: 1), (_) {
      final d = expiresAt.difference(DateTime.now());
      setState(()=> remaining = d.isNegative ? Duration.zero : d);
    });
  }
  @override void dispose(){ t.cancel(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final mm = remaining.inMinutes.remainder(60).toString().padLeft(2,'0');
    final ss = remaining.inSeconds.remainder(60).toString().padLeft(2,'0');

    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
                Text('FX: 57.25', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                SizedBox(height: 8),
                Text('Fee: 1.50   Receive: 5673.50 ETB'),
              ]),
            ),
          ),
          const Spacer(),
          Text('Quote expires in $mm:$ss', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: remaining==Duration.zero?null:(){}, child: const Text('Confirm & Send')),
        ]),
      ),
    );
  }
}
```

---

## 6) Run Instructions (Windows)

### Backend
```powershell
cd src\GuzPay.Api
dotnet restore
dotnet run
# API at http://localhost:5000 (configure Kestrel if different)
```

### Flutter (Android emulator)
```powershell
cd guzpay_app
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run --dart-define=API_BASE=http://10.0.2.2:5000
```

---

## 7) Demo Script

1) Launch backend + Flutter app.  
2) Login with `demo@guzpay.com / 123456`.  
3) Add beneficiary **“Meron H.”** (Telebirr).  
4) Send **$100** → Review shows FX/fee/receive + **countdown** → Confirm (2FA: `123456`).  
5) **Success** (confetti), then Transfers list shows **pending → settled** in ~15s.  
6) Toggle language to **Amharic**; labels update.

---

## 8) Tests (minimum)

- **Backend**: `QuoteTests.cs` (fee math, expiry), transfer idempotency test.  
- **Flutter**: widget test for Review (countdown visible), golden test for Success screen.

---

## 9) Acceptance Criteria

- End-to-end flow works locally on Android emulator.  
- Transfers flip from pending to settled automatically.  
- Modern, colorful UI with gradients, rounded corners, and animations.  
- EN/AM localization works.  
- At least one backend test and one Flutter test pass.

---

## 10) Notes & Next Steps

- Replace stub auth with real OTP/email later.  
- Move from SQLite to Postgres in production.  
- Add AML/KYC modules and bill-pay/investments in subsequent phases.  
- Introduce CI (GitHub Actions) to run tests on every PR.
