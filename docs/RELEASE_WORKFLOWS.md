# Fiyora / NFile release workflow contract

All three **publishing workflows live on `main`** (the default branch) for reliable GitHub Actions manual-dispatch discovery. They **do not** merge, rewrite or otherwise modify the source branch being built. Publishing uses explicit `workflow_dispatch` only.

| Workflow / Actions name | Source | Output | Default visibility |
|---|---|---|---|
| `.github/workflows/beta.yml` — beta (Fiyora preview) | Current `apk-beta` | Signed ARM64 Fiyora preview (package `com.noirero.fiyora.preview`) | Public GitHub **prerelease** after manual trigger |
| `.github/workflows/apk-build-original.yml` — apk-build (NFile Original) | **Pinned** `00dcc955bbb0af0c0b0d963f644e6980d1ed67e5` (and verify `apk-build` still points there) | Signed ABI-split NFile original (package `com.rubex.nfile`) | Public GitHub **prerelease**, not latest |
| `.github/workflows/release.yml` — release (Fiyora stable candidate) | `main` at dispatch time | Signed ABI-split Fiyora candidate (same package `com.rubex.nfile`) | **Draft** GitHub Release; owner must separately publish |

The original existing push workflow on `apk-beta` (`.github/workflows/apk-build.yml` in that branch) **continues producing CI artifacts**. It is separate from the new manually dispatched original NFile workflow (`.github/workflows/apk-build-original.yml` on `main`). Stable validation uses the existing beta **push CI** run ID to prove that a preview APK was successfully built for the exact beta commit.

## Required repository secrets

- **Fiyora preview**: existing `MRARE_KEYSTORE_BASE64`, `MRARE_KEY_ALIAS`, `MRARE_KEY_PASSWORD`, `MRARE_STORE_PASSWORD` (legacy names, kept for compatibility with the proven successful `apk-beta` build). Do not swap these for another key without a planned signing migration.
- **NFile original and Fiyora stable**: `KEYSTORE_BASE64`, `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD`. These must be the original signing key if preserving upgrade compatibility with the existing NFile package ID. The jobs fail closed when any signing secret is absent.
- The PR build check uses a **throwaway** signing key and does not distribute its APK as a release.

## Promotion protocol

1. Work and test on `apk-beta`. Its existing `APK Build` push workflow must be green for the specific SHA. Capture that run's numeric ID.
2. On **Actions → beta (Fiyora preview) → Run workflow** (choose `main`), produce the beta prerelease from the selected current `apk-beta` source. Check its source SHA and beta tag in the prerelease notes. Physically test **that** APK; check core filesystem operations, SAF/document provider, file permissions, upgrade/install behavior and crash regressions.
3. Promote the **tested** beta commit to `main` by a reviewed **merge commit**, not a squash/rebase-only history rewrite. Reconcile preview-only identity (`com.noirero.fiyora.preview`), launcher labels, notification IDs and provider authorities to the production behavior; retain production package `com.rubex.nfile` until product identity/signing migration is explicitly decided. Other concurrent untested changes invalidate a purely ancestor-based proof; require appropriate regression acceptance.
4. Ensure the open Fiyora rebranding PR (if still needed) is reviewed and integrated, and bump `pubspec.yaml` version and versionCode for install/upgrade compatibility. Note existing `main` was still named NFile at the time this workflow was prepared. **Do not use stable release before Fiyora branding is present in the actual main tree.**
5. On **Actions → release (Fiyora stable candidate) → Run workflow**, enter the tested Fiyora beta GitHub prerelease tag and the successful **existing `apk-beta` push CI** run ID. Confirm physical beta testing with the checkbox. The workflow verifies prerelease availability, CI branch/SHA/path/success, ancestry, production package ID and Fiyora launcher label, and checks for a duplicate stable tag.
6. The workflow compiles a new, differently signed production package. Validate the *exact* candidate APK SHA/checksums and install/upgrade behavior on a physical device. Only then manually publish its **draft GitHub Release**. Do not treat CI green or a preview test as final binary acceptance.

## Important limits

- Github Actions manual inputs/ancestry/CI cannot independently prove that a human physically tested the app. The release remains a draft for manual acceptance.
- A merge commit preserves tested beta ancestry; squash merges do **not**, and the stable guard will reject them. A passing ancestry check does not certify identical binaries or absence of unrelated changes.
- The stable `main` app and NFile original deliberately share `com.rubex.nfile` for upgrade compatibility. Preview uses a separate application ID and signing key. Stable signing must match the installed original key; its versionCode must exceed the previous installed production build.
- GitHub `workflow_dispatch` workflows must be present on the repository default branch to appear in the Actions UI. Before this PR merges, these new dispatch buttons are not active.
- The original app source `apk-build` branch and Fiyora beta `apk-beta` branch are **not modified** by this proposal.
- PR branch protection is a GitHub repository setting and must be configured by the owner; these files alone do not enforce review/merge restrictions.
- The Flutter Android build still inherits the upstream `flutter_avif_android` duplicate-Java-class workaround; this is a CI workaround, not a tested source fix.
