#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Script de post-clonage machine Windows en 3 étapes automatisées.
    /!\ IMPORTANT Placer ce script dans C:\Scripts sur le PC Maitre avant clonage.
	Taper ces commandes sur le PC Maitre avant clonage :
	# 1. Armer l'autologon
	$r = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
	Set-ItemProperty $r -Name AutoAdminLogon   -Value "1"
	Set-ItemProperty $r -Name DefaultUserName  -Value "Administrator"
	Set-ItemProperty $r -Name DefaultPassword  -Value "YOUR_PASSWORD_HERE"
	Set-ItemProperty $r -Name DefaultDomainName -Value "."

	# 2. Armer le RunOnce
	Set-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
    	-Name "AutoStartClone" `
    	-Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File C:\Scripts\PostClone.ps1"
.DESCRIPTION
    - Etape 1 : Quitte le domaine AD + renomme la machine, puis redémarre
    - Etape 2 : Rejoint le domaine AD, puis redémarre
    - Etape 3 : Télécharge et installe l'agent Tactical RMM, synchro GPO, nettoyage
.EXAMPLE
    .\PostClone.ps1
#>

# ╔══════════════════════════════════════════════════════════════╗
#  CONFIG — Remplir toutes ces variables avant de lancer le script
# ╚══════════════════════════════════════════════════════════════╝

# Domaine Active Directory cible
$Domain       = "domain.net"

# Compte admin du domaine (sans le domaine, il est ajouté automatiquement)
$AdminUser    = "Admin"

# Mot de passe de ce compte admin du domaine
$AdminPass    = "YOUR_PASSWORD_HERE"

# OU de destination dans l'AD
# Laisser vide ("") pour utiliser le conteneur par défaut (Computers)
$OUPath       = ""

# Nom du compte Administrateur local de la machine clonée
# (celui configuré en AutoAdminLogon sur le PC maître)
$LocalAdmin   = "Administrator"

# Mot de passe du compte Administrateur local
$LocalPass    = "YOUR_LOCAL_PASSWORD_HERE"

# Chemin du dossier contenant ce script (sera supprimé automatiquement à la fin)
$ScriptFolder = "C:\Scripts"

# Variables à mettre dans la CONFIG en haut (peut changer en fonction de la version de tactical RMM)
$TRMMDownloadLink = "https://github.com/amidaware/rmmagent/releases/download/v2.10.0/tacticalagent-v2.10.0-windows-amd64.exe"
$TRMMApi          = "https://api.domain.net"
$TRMMClientId     = ""
$TRMMSiteId       = ""
$TRMMAgentType    = "workstation / server"
$TRMMAuth         = "YOUR_TOKEN_HERE"

# ╔══════════════════════════════════════════════════════════════╗
#  VARIABLES INTERNES — ne pas modifier
# ╚══════════════════════════════════════════════════════════════╝
$RegPath      = "HKLM:\SOFTWARE\PostClone"
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$TempAgent    = "C:\Windows\Temp\tacticalagent.exe"
$LogFile      = "C:\Windows\Temp\PostClone.log"

# ───────────────────────────────────────────────────────────────
#  FONCTIONS
# ───────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

function Get-DomainCred {
    $secPass = ConvertTo-SecureString $AdminPass -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential("$Domain\$AdminUser", $secPass)
}

function Set-RunOnce {
    $cmd = "powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
                     -Name "PostClone" -Value $cmd
    Write-Log "RunOnce configuré"
}

# Force l'autologon local pour survivre aux redémarrages intermédiaires
function Enable-AutoLogon {
    Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon"  -Value "1"
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultUserName"  -Value $LocalAdmin
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultPassword"  -Value $LocalPass
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultDomainName" -Value "."
    Write-Log "AutoAdminLogon activé pour '$LocalAdmin'"
}

# Désactive l'autologon et efface le mot de passe du registre
function Disable-AutoLogon {
    Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value "0"
    Remove-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
    Write-Log "AutoAdminLogon désactivé, mot de passe supprimé du registre"
}

function Read-PCName {
    do {
        $name = Read-Host "Entrez le nouveau nom de cette machine"
        $name = $name.Trim()
        if ($name -eq "") {
            Write-Host "Le nom ne peut pas etre vide." -ForegroundColor Yellow
        } elseif ($name.Length -gt 15) {
            Write-Host "Le nom ne peut pas depasser 15 caracteres (norme NetBIOS)." -ForegroundColor Yellow
            $name = ""
        } elseif ($name -notmatch "^[a-zA-Z0-9\-]+$") {
            Write-Host "Le nom ne peut contenir que des lettres, chiffres et tirets." -ForegroundColor Yellow
            $name = ""
        }
    } while ($name -eq "")
    return $name
}

# ───────────────────────────────────────────────────────────────
#  LECTURE DE L'ETAT
# ───────────────────────────────────────────────────────────────
$step    = Get-ItemPropertyValue -Path $RegPath -Name "Step"    -ErrorAction SilentlyContinue
$NewName = Get-ItemPropertyValue -Path $RegPath -Name "NewName" -ErrorAction SilentlyContinue

# ════════════════════════════════════════════════════════════════
#  ETAPE 1 — Quitte le domaine + renomme
# ════════════════════════════════════════════════════════════════
if (-not $step) {

    # Demande interactive du nom de la machine
    Write-Host ""
    Write-Host "=== POST-CLONAGE — Etape 1/3 ===" -ForegroundColor Green
    Write-Host ""
    $NewName = Read-PCName

    Write-Log "=== ETAPE 1 : Démarrage post-clonage pour '$NewName' ==="

    # Initialisation du registre
    New-Item -Path $RegPath -Force | Out-Null
    Set-ItemProperty -Path $RegPath -Name "Step"    -Value 1
    Set-ItemProperty -Path $RegPath -Name "NewName" -Value $NewName
    Write-Log "Registre initialisé (Step=1, NewName=$NewName)"

    # Blindage de l'autologon local pour les redémarrages intermédiaires
    # (au cas où la jonction AD perturberait la config Winlogon)
    Enable-AutoLogon
    Set-RunOnce

    $cred = Get-DomainCred

    # Sortie du domaine
    Write-Log "Sortie du domaine AD..."
    try {
        Remove-Computer -UnjoinDomainCredential $cred -PassThru -Force -ErrorAction Stop
        Write-Log "Sortie du domaine OK"
    } catch {
        Write-Log "Erreur lors de la sortie du domaine : $_" "WARN"
        # On continue — la machine est peut-être déjà en workgroup
    }

    # Renommage
    Write-Log "Renommage en '$NewName'..."
    try {
        Rename-Computer -NewName $NewName -Force -ErrorAction Stop
        Write-Log "Renommage OK"
    } catch {
        Write-Log "Erreur lors du renommage : $_" "ERROR"
        Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
        exit 1
    }

    Set-ItemProperty -Path $RegPath -Name "Step" -Value 2
    Write-Log "Step mis à 2. Redémarrage dans 3 secondes..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

# ════════════════════════════════════════════════════════════════
#  ETAPE 2 — Rejoint le domaine
# ════════════════════════════════════════════════════════════════
elseif ($step -eq 2) {

    Write-Log "=== ETAPE 2 : Jonction au domaine '$Domain' ==="

    # Réaffirme l'autologon local (sécurité après la jonction AD)
    Enable-AutoLogon
    Set-RunOnce

    $cred = Get-DomainCred

    Write-Log "Jonction au domaine..."
    try {
        $joinParams = @{
            DomainName  = $Domain
            Credential  = $cred
            Force       = $true
            ErrorAction = "Stop"
        }
        if ($OUPath -ne "") { $joinParams["OUPath"] = $OUPath }
        Add-Computer @joinParams
        Write-Log "Jonction au domaine OK"
    } catch {
        Write-Log "Erreur lors de la jonction au domaine : $_" "ERROR"
        exit 1
    }

    Set-ItemProperty -Path $RegPath -Name "Step" -Value 3
    Write-Log "Step mis à 3. Redémarrage dans 3 secondes..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

# ════════════════════════════════════════════════════════════════
#  ETAPE 3 — Install TRMM + GPO + nettoyage
# ════════════════════════════════════════════════════════════════
elseif ($step -eq 3) {

    Write-Log "=== ETAPE 3 : Installation de l'agent Tactical RMM ==="

# Attente réseau (max 15 secondes)
$apiHost = ($TRMMApi -replace "https://","")
$X = 0
do {
    Write-Log "Attente réseau..."
    Start-Sleep -Seconds 5
    $X++
} until ((Test-NetConnection $apiHost -Port 443 -ErrorAction SilentlyContinue).TcpTestSucceeded -or $X -eq 3)

# Exclusions Defender
try {
    if ((Get-MpComputerStatus).AntivirusEnabled) {
        Add-MpPreference -ExclusionPath 'C:\Program Files\TacticalAgent\*'
        Add-MpPreference -ExclusionPath 'C:\Program Files\Mesh Agent\*'
        Add-MpPreference -ExclusionPath 'C:\ProgramData\TacticalRMM\*'
    }
} catch {}

# Téléchargement
Write-Log "Téléchargement de l'agent..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $TRMMDownloadLink -OutFile $TempAgent -UseBasicParsing -ErrorAction Stop
Write-Log "Téléchargement OK"

# Extraction
Write-Log "Extraction..."
Start-Process -FilePath $TempAgent -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES" -Wait
Start-Sleep -Seconds 5

# Installation et enregistrement
Write-Log "Installation et enregistrement sur le panel..."
$installArgs = @(
    "-m", "install",
    "--api", "`"$TRMMApi`"",
    "--client-id", $TRMMClientId,
    "--site-id", $TRMMSiteId,
    "--agent-type", "`"$TRMMAgentType`"",
    "--auth", "`"$TRMMAuth`""
)
$proc = Start-Process -FilePath "C:\Program Files\TacticalAgent\tacticalrmm.exe" `
                      -ArgumentList $installArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Log "Erreur installation TRMM (code $($proc.ExitCode))" "ERROR"
    exit 1
}
Write-Log "Installation TRMM OK"

    # Synchro GPO
    Write-Log "Synchronisation des GPO..."
    & gpupdate /force
    Write-Log "GPO synchronisées"

    # Nettoyage
    Write-Log "Nettoyage..."
    Remove-Item -Path $RegPath   -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $TempAgent -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
                        -Name "PostClone" -ErrorAction SilentlyContinue

    # Suppression du dossier script
    Write-Log "Suppression du dossier script '$ScriptFolder'..."
    Remove-Item -Path $ScriptFolder -Recurse -Force -ErrorAction SilentlyContinue

    # Désactivation de l'autologon et suppression du mot de passe local du registre
    Disable-AutoLogon

    Write-Log "=== POST-CLONAGE TERMINÉ === Log disponible dans $LogFile"
    Write-Host ""
    Write-Host "=== POST-CLONAGE TERMINÉ ===" -ForegroundColor Green
}

# ════════════════════════════════════════════════════════════════
#  ETAT INCONNU
# ════════════════════════════════════════════════════════════════
else {
    Write-Log "Valeur d'étape inconnue dans le registre ($step). Nettoyage et arrêt." "ERROR"
    Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
    exit 1
}
