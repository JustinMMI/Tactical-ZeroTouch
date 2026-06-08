# 🚀 Tactical-ZeroTouch — Automated Windows Post-Clone Tactical RMM Deployment 

A robust Windows PowerShell script that fully automates the post-cloning setup of a machine in an Active Directory environment. It handles the domain re-joining process, automatic reboots, and the silent installation of the Tactical RMM agent without any user intervention.

## ✨ Features

* 🔄 **3-Step Automation** — Survives multiple reboots using the `RunOnce` registry key.
* 🏷️ **Smart Identity** — Automatically leaves the domain, renames the PC, and joins the domain cleanly to avoid Active Directory SID conflicts.
* 🤖 **Zero-Touch (Almost)** — Only asks for the new PC name once at startup, then handles everything else automatically.
* 📡 **Tactical RMM Integration** — Downloads, extracts, and silently registers the TRMM agent directly to your panel.
* 🧹 **Self-Cleaning** — Deletes temporary installers, clears the registry keys, disables the `AutoAdminLogon`, and deletes itself when finished.

## 🚀 Usage

### 1. Script Configuration

1. Open `PostClone.ps1` in an editor (like Notepad or VSCode).
2. Fill in all the variables in the `# CONFIG` section:
* Your Active Directory `$Domain`, `$AdminUser`, and `$AdminPass`.
* Your `$LocalAdmin` and `$LocalPass` (crucial for the automatic reboots).
* Your Tactical RMM API URL, Download Link, IDs, and Auth Token.


3. Save the file.

### 2. Master PC Preparation (Before Cloning)

1. On your fully configured Master PC (Golden Image), create a folder named `C:\Scripts`.
2. Place your configured `PostClone.ps1` inside `C:\Scripts\`.
3. Open a **PowerShell console as Administrator**.
4. Copy and paste the following commands to arm the `AutoAdminLogon` (replace `YOUR_LOCAL_PASSWORD`):
```powershell
$r = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $r -Name AutoAdminLogon   -Value "1"
Set-ItemProperty $r -Name DefaultUserName  -Value "Administrator"
Set-ItemProperty $r -Name DefaultPassword  -Value "YOUR_LOCAL_PASSWORD"
Set-ItemProperty $r -Name DefaultDomainName -Value "."

```


5. Copy and paste the following command to arm the script for the next boot:
```powershell
Set-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "AutoStartClone" -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File C:\Scripts\PostClone.ps1"

```


6. ⚠️ **SHUT DOWN THE PC IMMEDIATELY.** Do not restart or log off, otherwise the script will trigger on the Master PC and break its configuration.
7. Clone the hard drive of this Master PC.

### 3. Deployment

1. Deploy your clone image to a new PC and turn it on.
2. The PC will automatically log into the local Administrator session.
3. A blue PowerShell window will appear automatically.
4. Type the new name of the PC and press `Enter`.
5. Walk away. The script will:
* Leave the AD, rename the PC, and reboot.
* Auto-login, join the AD with the new name, and reboot.
* Auto-login, install Tactical RMM, sync GPOs, secure the PC (disable AutoLogon), and clean up all files.



## ⚠️ Disclaimer

This script stores sensitive passwords (AD Admin and Local Admin) in **plain text** inside the `.ps1` file.

If you want to use it securely in a production environment:

1. Download [PS2EXE](https://github.com/MScholtes/PS2EXE) (or use the `Invoke-ps2exe` module).
2. Compile your configured `PostClone.ps1` into an executable (`PostClone.exe`).
3. Update the `RunOnce` registry command in the preparation steps to target your new `.exe` instead of the `.ps1` file.
4. This will obscure your credentials from anyone exploring the local drive.

## 🖥️ Compatibility

Tested on **Windows 10 / Windows 11** with **IACA** and **Windows Clone**.

---

# French

Un script PowerShell robuste qui automatise entièrement la configuration post-clonage d'une machine dans un environnement Active Directory. Il gère le processus de reconnexion au domaine, les redémarrages automatiques et l'installation silencieuse de l'agent Tactical RMM sans aucune intervention de l'utilisateur.

## ✨ Fonctionnalités

* 🔄 **Automatisation en 3 étapes** — Survit à plusieurs redémarrages en utilisant la clé de registre `RunOnce`.
* 🏷️ **Identité intelligente** — Quitte automatiquement le domaine, renomme le PC et rejoint le domaine proprement pour éviter les conflits de SID dans l'Active Directory.
* 🤖 **Zero-Touch (Presque)** — Ne demande le nouveau nom du PC qu'une seule fois au démarrage, puis gère tout le reste automatiquement.
* 📡 **Intégration Tactical RMM** — Télécharge, extrait et enregistre silencieusement l'agent TRMM directement sur votre panel.
* 🧹 **Auto-Nettoyage** — Supprime les installeurs temporaires, nettoie les clés de registre, désactive l'`AutoAdminLogon` et se supprime lui-même une fois terminé.

## 🚀 Utilisation

### 1. Configuration du Script

1. Ouvrez `PostClone.ps1` dans un éditeur (comme le Bloc-notes ou VSCode).
2. Remplissez toutes les variables dans la section `# CONFIG` :
* Votre `$Domain` Active Directory, `$AdminUser`, et `$AdminPass`.
* Votre `$LocalAdmin` et `$LocalPass` (crucial pour les redémarrages automatiques).
* L'URL de l'API Tactical RMM, le lien de téléchargement, les IDs et le Token d'authentification.


3. Sauvegardez le fichier.

### 2. Préparation du PC Maître (Avant le clonage)

1. Sur votre PC Maître entièrement configuré (Image d'Or), créez un dossier nommé `C:\Scripts`.
2. Placez votre `PostClone.ps1` configuré dans `C:\Scripts\`.
3. Ouvrez une **console PowerShell en tant qu'Administrateur**.
4. Copiez-collez les commandes suivantes pour armer l'`AutoAdminLogon` (remplacez `VOTRE_MOT_DE_PASSE_LOCAL`) :
```powershell
$r = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $r -Name AutoAdminLogon   -Value "1"
Set-ItemProperty $r -Name DefaultUserName  -Value "Administrateur"
Set-ItemProperty $r -Name DefaultPassword  -Value "VOTRE_MOT_DE_PASSE_LOCAL"
Set-ItemProperty $r -Name DefaultDomainName -Value "."

```


5. Copiez-collez la commande suivante pour armer le script au prochain démarrage :
```powershell
Set-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "AutoStartClone" -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File C:\Scripts\PostClone.ps1"

```


6. ⚠️ **ÉTEIGNEZ LE PC IMMÉDIATEMENT.** Ne redémarrez pas et ne fermez pas la session, sinon le script se déclenchera sur le PC Maître et cassera sa configuration.
7. Clonez le disque dur de ce PC Maître.

### 3. Déploiement

1. Déployez votre image clonée sur un nouveau PC et allumez-le.
2. Le PC se connectera automatiquement à la session Administrateur locale.
3. Une fenêtre PowerShell bleue apparaîtra automatiquement.
4. Tapez le nouveau nom du PC et appuyez sur `Entrée`.
5. Vous pouvez partir. Le script va :
* Quitter l'AD, renommer le PC, et redémarrer.
* S'auto-connecter, rejoindre l'AD avec le nouveau nom, et redémarrer.
* S'auto-connecter, installer Tactical RMM, synchroniser les GPO, sécuriser le PC (désactiver l'AutoLogon), et nettoyer tous les fichiers.



## ⚠️ Avertissement

Ce script stocke des mots de passe sensibles (Admin AD et Admin Local) en **texte clair** dans le fichier `.ps1`.

Si vous souhaitez l'utiliser de manière sécurisée en production :

1. Téléchargez [PS2EXE](https://github.com/MScholtes/PS2EXE) (ou utilisez le module `Invoke-ps2exe`).
2. Compilez votre `PostClone.ps1` configuré en un exécutable (`PostClone.exe`).
3. Mettez à jour la commande de registre `RunOnce` dans les étapes de préparation pour cibler votre nouveau `.exe` au lieu du fichier `.ps1`.
4. Cela masquera vos identifiants à quiconque explorerait le disque local.

## 🖥️ Compatibilité

Testé sur **Windows 10 / Windows 11** avec **IACA** et **l'outil de sauvegarde Windows**.
