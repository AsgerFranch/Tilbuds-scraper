# Tilbudsjæger – REMA 1000, Netto, Føtex & Coop 365

Statisk web-app der henter og sorterer tilbud og priser fra **REMA 1000**, **Netto**, **Føtex** og **Coop 365discount** efter:
- 🏷️ **Mest nedsat (%)** og 💰 **Mest nedsat (kr)**
- ⚖️ **Laveste kilopris (`kr/kg`)**
- 🎯 **Magert protein pr. kr** & 💪 **Mest protein pr. kr (`g/kr`)**
- 🔋 **Flest kalorier pr. kr (`kcal/kr`)**

## Sådan udgiver du den gratis som hjemmeside på GitHub Pages

1. **Upload filerne i denne mappe til et GitHub-repository** (`index.html`, `data.js`, `opdater.ps1`, `start.cmd` og mappen `.github/workflows/opdater-tilbud.yml`).
2. Gå ind på dit repository på GitHub → **Settings** → **Pages**.
3. Under **Build and deployment** → **Source**, vælg **Deploy from a branch**, og vælg **`main`** (og `/ (root)`) → klik **Save**.

Din hjemmeside er nu live på `https://<dit-brugernavn>.github.io/<repo-navn>/`!

### Automatisk daglig opdatering (uden din PC)
Filen `.github/workflows/opdater-tilbud.yml` sørger for, at GitHub automatisk kører `opdater.ps1` hver morgen kl. 06:15 dansk tid og gemmer den nye `data.js`, så hjemmesiden altid har dagens nyeste tilbud. Du kan også opdatere når som helst ved at klikke **Actions → Opdater Tilbud → Run workflow** inde på GitHub.
