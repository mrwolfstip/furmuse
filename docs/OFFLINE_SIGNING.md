# build, sign and host furmuse

## 1. build the unsigned ipa

On a Mac with Xcode and Rust installed, open Terminal in the project folder:

```sh
chmod +x scripts/makeipa.sh scripts/signipa.sh scripts/make-install-manifest.sh
./scripts/makeipa.sh
```

The unsigned file is `build/furmuse.ipa`. It cannot be installed directly. You can publish this unsigned file on GitHub so each user can sign it with their own Apple ID.

## 2. sign completely offline

You need a signing certificate exported from Keychain Access as a `.p12`, its password, and a matching `.mobileprovision` downloaded from your Apple Developer account. For direct device installation, use a Development or Ad Hoc profile containing that device's UDID.

Keep those files outside the repository, then run:

```sh
./scripts/signipa.sh \
  build/furmuse.ipa \
  /path/to/certificate.p12 \
  /path/to/profile.mobileprovision \
  build/furmuse-signed.ipa
```

The script asks for the `.p12` password without showing it. It creates a temporary keychain, signs embedded code and the app, verifies the signature, writes the signed IPA, and removes the temporary keychain. Nothing is uploaded. Do not commit a `.p12`, provisioning profile, password, or signed private build.

The certificate and profile must belong together. The app only installs on devices and until the expiration date allowed by that profile.

## about “anti-revoke” certificates

There is no Apple certificate type that guarantees “anti-revoke.” Offline signing keeps your certificate away from third-party signing services, but Apple can still expire or revoke it.

- Development and Ad Hoc builds only install on registered device UDIDs.
- Free Apple ID signing is normally short-lived and must be refreshed.
- Apple Enterprise distribution is for an eligible organisation's internal users, not public app distribution. Misuse can be revoked.
- Leaked or purchased shared certificates are unsafe and are commonly revoked.
- For general public installation, use the App Store or TestFlight.

## 3. publish on GitHub

The repository workflow publishes `build/furmuse.ipa` as an **unsigned** release asset. This is the safe public option: users download it and sign it with their own account using Xcode, Sideloadly, AltStore, or another trusted local tool.

To upload a release manually:

```sh
gh release create v1 build/furmuse.ipa \
  --repo mrwolfstip/furmuse \
  --title "furmuse v1" \
  --notes "unsigned ipa — sign locally before installing"
```

Safari cannot install an unsigned IPA merely because it is hosted on GitHub. A signed Ad Hoc IPA remains limited to the UDIDs in its provisioning profile. GitHub Release download redirects can also make OTA manifests unreliable, so use your own HTTPS site for OTA installation.

## 4. host a permitted signed build on your website

Upload `furmuse-signed.ipa` to an HTTPS URL, then create its manifest:

```sh
./scripts/make-install-manifest.sh \
  build/furmuse-signed.ipa \
  https://example.com/furmuse/furmuse-signed.ipa \
  build/manifest.plist
```

Upload `build/manifest.plist` beside the IPA. Set the server MIME types to:

```text
.ipa    application/octet-stream
.plist  application/xml
```

Add this link to an HTTPS page, replacing the encoded manifest URL with yours:

```html
<a href="itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fexample.com%2Ffurmuse%2Fmanifest.plist">
  install furmuse
</a>
```

Open the page in Safari on an authorised iPhone and tap the link. If installation fails, first check that the device UDID is in the profile, the certificate and profile have not expired or been revoked, the bundle identifier matches, and both files are served over HTTPS.
