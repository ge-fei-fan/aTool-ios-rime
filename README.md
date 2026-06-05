# FITNEX

SwiftUI prototype generated from the FITNEX Fitness Mobile App UI Kit.

## Build IPA with GitHub Actions

1. Push this repository to GitHub on the `main` branch.
2. Open **Actions**.
3. Run **Build TrollStore IPA** manually, or let it run on `main` pushes.
4. Download the `FITNEX-TrollStore` artifact.
5. Open `FITNEX-TrollStore.ipa` with TrollStore on a supported device.

The workflow builds an unsigned Release app and packages it as:

```text
Payload/Simpanin.app
FITNEX-TrollStore.ipa
```

The app targets iOS 16.0 and uses bundle ID `com.local.fitnex`.
