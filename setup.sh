#!/usr/bin/env bash
set -e

# Install Flutter SDK (for web builds in Codespaces)
if [ ! -d /opt/flutter ]; then
  sudo git clone https://github.com/flutter/flutter.git -b stable /opt/flutter
  sudo chown -R $USER:$USER /opt/flutter
fi

echo 'export PATH=/opt/flutter/bin:$PATH' >> ~/.bashrc
export PATH=/opt/flutter/bin:$PATH

flutter --version || true
flutter config --enable-web || true
flutter doctor -v || true

# .NET restore if project exists
if [ -d "src/GuzPay.Api" ]; then
  cd src/GuzPay.Api
  dotnet restore || true
fi
