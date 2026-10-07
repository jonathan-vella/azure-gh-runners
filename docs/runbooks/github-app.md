# Runbook: GitHub App

The platform uses one GitHub App owned by the personal account. The KEDA scaler and the init container use it to observe
queued jobs and mint single-use JIT runner configs. Its private key grants Administration read/write on every installed
repository, so handle it as the highest-value secret in the platform.

| Item | Value |
| --- | --- |
| App slug | `jonathan-vella-gh-runners` |
| Permissions | Repository Administration read/write, Actions read, Metadata read |
| Webhook / events | None |
| Visibility | Private (not public) |
| Installation | "Only select repositories" |
| Secrets (`platform-prod` environment) | `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY` |

The private key is also written to Key Vault by the platform deployment (`iac-identity-kv`) from the
`GH_APP_PRIVATE_KEY` secret. It must never be committed, printed, or logged.

## 1. Create the App

Create it at <https://github.com/settings/apps/new> (personal account) with:

- Name: `jonathan-vella-gh-runners` (names are globally unique; adjust if taken)
- Homepage URL: `https://github.com/jonathan-vella/azure-gh-runners`
- Webhook: **uncheck Active**
- Repository permissions: Administration **Read and write**, Actions **Read-only**, Metadata **Read-only**
- Where can this App be installed: **Only on this account**

Then click **Generate a private key**. The downloaded `.pem` is the only copy: store it straight into the environment
secret and delete the file.

```bash
gh secret set GH_APP_PRIVATE_KEY --env platform-prod --repo jonathan-vella/azure-gh-runners < downloaded-key.pem
shred -u downloaded-key.pem   # PowerShell: Remove-Item downloaded-key.pem
gh secret set GH_APP_ID --env platform-prod --repo jonathan-vella/azure-gh-runners --body <app-id>
```

## 2. Install on a repository

1. Open `https://github.com/apps/<slug>/installations/new`, or **Configure** on an existing installation under
   <https://github.com/settings/installations>.
2. Choose **Only select repositories** and select only the repository being onboarded (initially `ghr-smoke`).
3. The first time, record the installation ID (the number in `…/settings/installations/<id>`):

   ```bash
   gh secret set GH_APP_INSTALLATION_ID --env platform-prod --repo jonathan-vella/azure-gh-runners --body <id>
   ```

Adding a repository later reuses the same installation and ID. Never select **All repositories**.

## 3. Rotate the private key

1. App settings → **Generate a private key**. Both keys are valid until the old one is deleted.
2. Update the secret: `gh secret set GH_APP_PRIVATE_KEY --env platform-prod --repo jonathan-vella/azure-gh-runners < new.pem`,
   then delete `new.pem`.
3. Run the `platform-prod` deploy workflow so Key Vault receives the new key, and confirm a runner job still starts.
4. Delete the old key in App settings.

Rotate on a schedule (the maintenance workflow opens a reminder issue) and immediately on any suspected exposure.

## Verify

```bash
gh secret list --env platform-prod --repo jonathan-vella/azure-gh-runners   # three GH_APP_* secrets
```

App settings must show no webhook, private visibility, and only the permissions listed above.
