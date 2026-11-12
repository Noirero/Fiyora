# FIYORA — Three manual APK workflows

| Actions workflow | Select branch | APK source | Result |
|---|---|---|---|
| `Fiyora Stable (manual)` | `main` | Exact dispatched `main` SHA | **Public GitHub Release**, not draft/prerelease |
| `beta — Fiyora Beta (manual)` | `apk-beta` | Exact dispatched `apk-beta` SHA | **Actions artifact** containing signed ARM64 Beta APK + SHA256SUMS; **no GitHub Release** |
| `apk-build — NFile Original (manual)` | `apk-build` | Frozen NFile source commit `00dcc955bbb0af0c0b0d963f644e6980d1ed67e5` | **Actions artifact** containing signed original ABI-split APKs + SHA256SUMS; **no GitHub Release** |

## How to run

Open GitHub **Actions**, select the workflow, click **Run workflow**, choose the branch from the table, and run it.
All three APK workflows use only `workflow_dispatch`; push/commit alone cannot publish a GitHub release. The separate `Fiyora PR Build Check` workflow validates changes targeting `main` but cannot publish.

- **Stable**: Runs Flutter tests, checks production package and branding, signs three ABI-split APKs, verifies signatures/checksums and checks that the `main` source has not moved. After success, it publishes **directly** as a public, non-prerelease GitHub Release under a unique `v<version>` tag. Running this workflow is the explicit publication action; there is no extra draft/publish step.
- **Beta**: Builds the exact selected `apk-beta` commit with preview signing. Download the output ZIP under **Actions → completed workflow run → Artifacts**. The ZIP contains the APK and `SHA256SUMS.txt`. No prerelease is created.
- **Original**: Runs on the selected `apk-build` branch but checks out the **frozen original NFile source commit** for compilation. Download the ZIP under **Actions → completed workflow run → Artifacts**; it contains APKs for ARM64, ARMv7 and x86_64 plus checksums. No prerelease is created.

## Branch setup and prerequisites

- GitHub needs `.github/workflows/beta.yml` on both `main` and `apk-beta` to make `apk-beta` a genuine dispatchable option. PR **#13** adds the Beta branch file; PR **#14** updates the default branch file.
- Likewise, `.github/workflows/apk-build.yml` must exist on both `main` and `apk-build`. PR **#15** adds the workflow-only file to `apk-build`; PR **#14** updates the default branch version. **The application source of NFile Original is not changed**; the build checks out the frozen original commit.
- Before PR #16 is merged, `main` still uses the NFile launcher label. The Stable workflow intentionally **fails** until FIYORA branding and package ID `com.noirero.fiyora` are present on `main`. Do not label an unbranded NFile APK as FIYORA Stable.
- Stable uses `com.noirero.fiyora`, Beta uses `com.noirero.fiyora.preview`, and Original NFile keeps `com.rubex.nfile`. These are three distinct Android apps and can be installed side by side. Stable is not an in-place update of NFile; app-private data is not automatically migrated. Use a controlled long-lived Stable signing key.

## Signing and download

- **Beta** secrets: `MRARE_KEYSTORE_BASE64`, `MRARE_KEY_ALIAS`, `MRARE_KEY_PASSWORD`, `MRARE_STORE_PASSWORD`.
- **Stable / Original** secrets: `KEYSTORE_BASE64`, `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD`.
- The workflows fail if mandatory signing secrets are unavailable. APK package/signing checks and SHA-256 checksums remain in place. No keystore is committed.
- GitHub Actions artifacts are retained for a limited period and downloads can require GitHub login. They are **not** GitHub Releases.
- CI success does not establish physical-device acceptance. Because Stable is now **direct public publication**, the owner should verify release readiness **before** selecting Run workflow. No automatic merge, workflow dispatch or publication is implied by preparing the PRs.

## Change coordination

PRs **#13, #14 and #15** are companion manual-workflow changes. Review the exact final diffs and validation together; keep them draft until the owner authorizes integration. PR #12 (archive rollback safety) is unrelated and must not be merged as part of the workflow migration.
