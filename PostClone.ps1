#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Script de post-clonage machine Windows en 4 etapes automatisees.
    /!\ IMPORTANT Placer ce script dans C:\Scripts sur le PC Maitre avant clonage.
	/!\ Si vous avez déjà executé une première fois le script sur votre ordinateur, avant toute chose, veuiller taper cette commande dans une fenêtre powershell en administrateur : -Remove-Item -Path "HKLM:\SOFTWARE\PostClone" -Force -Recurse -ErrorAction SilentlyContinue
	Tapez ces commandes dans une fenêtre powershell en administrateur sur le PC Maitre avant clonage :
	# 1. Armer l'autologon
	$r = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
	Set-ItemProperty $r -Name AutoAdminLogon   -Value "1"
	Set-ItemProperty $r -Name DefaultUserName  -Value "YourLocalAdmin"
	Set-ItemProperty $r -Name DefaultPassword  -Value "YourLocalPassword"
	Set-ItemProperty $r -Name DefaultDomainName -Value "."

	# 2. Armer le RunOnce
	Set-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
    	-Name "AutoStartClone" `
    	-Value "powershell.exe -NoExit -ExecutionPolicy Bypass -WindowStyle Normal -File C:\Scripts\PostClone.ps1"

	~~ Si vous souhaitez finalement annuler le démarrage du script, ou si vous avez eu une erreur sur une machine lors de l'execution de celui-ci, vous devez taper ces commabdes : ~
	-Remove-Item -Path "HKLM:\SOFTWARE\PostClone" -Force -Recurse -ErrorAction SilentlyContinue
	Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoAdminLogon -Value "0"
	Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultPassword -ErrorAction SilentlyContinue
.DESCRIPTION
    - Etape 1 : Quitte le domaine AD (WMI, force locale, sans contact DC), puis redemarre
    - Etape 2 : Renomme la machine (en workgroup, sans credentials AD), puis redemarre
    - Etape 3 : Rejoint le domaine AD, puis redemarre
    - Etape 4 : Telecharge et installe l'agent Tactical RMM, synchro GPO, nettoyage
.EXAMPLE
    .\PostClone.ps1
#>

# +==============================================================+
#  CONFIG - Remplir toutes ces variables avant de lancer le script
# +==============================================================+

# Domaine Active Directory cible
$Domain       = "yourdomain.local"

# Compte admin du domaine (sans le domaine, il est ajoute automatiquement)
$AdminUser    = "YourDomainAdmin"

# Mot de passe de ce compte admin du domaine
$AdminPass    = "YourDomainPassword"

# OU de destination dans l'AD (a remplir avec l'informaticien)
# Exemple : "OU=Workstations,DC=yourdomain,DC=local"
# Laisser vide ("") pour utiliser le conteneur par defaut (Computers)
$OUPath       = ""

# Nom du compte Administrateur local de la machine clonee
# (celui configure en AutoAdminLogon sur le PC maitre)
$LocalAdmin   = "YourLocalAdmin"

# Mot de passe du compte Administrateur local
$LocalPass    = "YourLocalPassword"

# Chemin du dossier contenant ce script (sera supprime automatiquement a la fin)
$ScriptFolder = "C:\Scripts"

# Variables a mettre dans la CONFIG en haut (peut changer en fonction de la version de tactical RMM)
$TRMMDownloadLink = "https://github.com/amidaware/rmmagent/releases/download/v2.10.0/tacticalagent-v2.10.0-windows-amd64.exe"
$TRMMApi          = "https://api.yourtrmm.com"
$TRMMClientId     = "YOUR_CLIENT_ID"
$TRMMSiteId       = "YOUR_SITE_ID"
$TRMMAgentType    = "workstation"
$TRMMAuth         = "YOUR_AUTH_TOKEN"

# +==============================================================+
#  VARIABLES INTERNES - ne pas modifier
# +==============================================================+
$RegPath      = "HKLM:\SOFTWARE\PostClone"
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$TempAgent    = "C:\Windows\Temp\tacticalagent.exe"
$LogFile      = "C:\Windows\Temp\PostClone.log"

# ---------------------------------------------------------------
#  FONCTIONS
# ---------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "ERROR" {
            Write-Host $line -ForegroundColor Red
            Write-Host "" 
            Write-Host "Appuyez sur Entree pour fermer..." -ForegroundColor Red
            Read-Host
        }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

function Get-DomainCred {
    $secPass = ConvertTo-SecureString $AdminPass -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential("$Domain\$AdminUser", $secPass)
}

function Set-RunOnce {
    $cmd = "powershell.exe -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
                     -Name "PostClone" -Value $cmd
    Write-Log "RunOnce configure"
}

# Force l'autologon local pour survivre aux redemarrages intermediaires
function Enable-AutoLogon {
    Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon"   -Value "1"
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultUserName"  -Value $LocalAdmin
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultPassword"  -Value $LocalPass
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultDomainName" -Value "."
    Write-Log "AutoAdminLogon active pour '$LocalAdmin'"
}

# Desactive l'autologon et efface le mot de passe du registre
function Disable-AutoLogon {
    Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value "0"
    Remove-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
    Write-Log "AutoAdminLogon desactive, mot de passe supprime du registre"
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

# ---------------------------------------------------------------
#  LECTURE DE L'ETAT
# ---------------------------------------------------------------
$step    = if (Test-Path $RegPath) { Get-ItemPropertyValue -Path $RegPath -Name "Step"    -ErrorAction SilentlyContinue } else { $null }
$NewName = if (Test-Path $RegPath) { Get-ItemPropertyValue -Path $RegPath -Name "NewName" -ErrorAction SilentlyContinue } else { $null }

# ================================================================
#  ETAPE 1 - Quitte le domaine uniquement
# ================================================================
if (-not $step) {

    # Demande interactive du nom de la machine
    Write-Host ""
    Write-Host "=== POST-CLONAGE - Etape 1/4 : Sortie du domaine ===" -ForegroundColor Green
    Write-Host ""
    $NewName = Read-PCName

    Write-Log "=== ETAPE 1 : Demarrage post-clonage pour '$NewName' ==="

    # Initialisation du registre
    New-Item -Path $RegPath -Force | Out-Null
    Set-ItemProperty -Path $RegPath -Name "Step"    -Value 1
    Set-ItemProperty -Path $RegPath -Name "NewName" -Value $NewName
    Write-Log "Registre initialise (Step=1, NewName=$NewName)"

    # Blindage de l'autologon local pour les redemarrages intermediaires
    Enable-AutoLogon
    Set-RunOnce

    # Detection de l'etat de jonction reel de la machine
    $cs = Get-WmiObject -Class Win32_ComputerSystem
    $estDansDomaine = ($cs.PartOfDomain -eq $true)
    Write-Log "PartOfDomain = $estDansDomaine"

    if ($estDansDomaine) {
        # Sortie du domaine via WMI avec credentials locaux - 100% silencieux, pas de popup
        # UnjoinDomainOrWorkgroup(Password, UserName, FJoinOptions)
        # FJoinOptions = 0 : sortie locale sans suppression du compte AD
        Write-Log "Sortie du domaine AD vers Workgroup (WMI, credentials domaine '$Domain\$AdminUser')..."
        try {
            $cs = Get-WmiObject -Class Win32_ComputerSystem
            $result = $cs.UnjoinDomainOrWorkgroup($AdminPass, "$Domain\$AdminUser", 0)
            if ($result.ReturnValue -ne 0) {
                Write-Log "Echec WMI UnjoinDomain, code retour : $($result.ReturnValue)" "ERROR"
                Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
                exit 1
            }
            Write-Log "Sortie du domaine OK (redemarrage necessaire pour prendre effet)"
        } catch {
            Write-Log "Erreur lors de la sortie du domaine : $_" "ERROR"
            Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
            exit 1
        }

        Set-ItemProperty -Path $RegPath -Name "Step" -Value 2
        Write-Log "Step mis a 2. Redemarrage dans 3 secondes..."
        Start-Sleep -Seconds 3
        Restart-Computer -Force

    } else {
        # Machine deja en workgroup (clonage l'a detachee du domaine)
        # Pas besoin de reboot intermediaire - on passe directement au renommage
        Write-Log "Machine deja en workgroup, pas de sortie de domaine necessaire"
        Write-Log "Passage direct au renommage (Step=2) sans redemarrage intermediaire"
        Set-ItemProperty -Path $RegPath -Name "Step" -Value 2

        # Renommage immediat puisqu'on est deja en workgroup
        Write-Log "Renommage en '$NewName'..."
        try {
            Rename-Computer -NewName $NewName -Force -ErrorAction Stop
            Write-Log "Renommage OK"
        } catch {
            Write-Log "Erreur lors du renommage : $_" "ERROR"
            Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
            exit 1
        }

        Set-ItemProperty -Path $RegPath -Name "Step" -Value 3
        Write-Log "Step mis a 3. Redemarrage dans 3 secondes..."
        Start-Sleep -Seconds 3
        Restart-Computer -Force
    }
}

# ================================================================
#  ETAPE 2 - Renommage (machine deja en workgroup, pas de creds AD)
# ================================================================
elseif ($step -eq 2) {

    Write-Host ""
    Write-Host "=== POST-CLONAGE - Etape 2/4 : Renommage en '$NewName' ===" -ForegroundColor Green
    Write-Host ""
    Write-Log "=== ETAPE 2 : Renommage de la machine en '$NewName' ==="

    # Reaffirme l'autologon local
    Enable-AutoLogon
    Set-RunOnce

    # Renommage sans credentials AD : la machine est desormais en workgroup
    Write-Log "Renommage en '$NewName'..."
    try {
        Rename-Computer -NewName $NewName -Force -ErrorAction Stop
        Write-Log "Renommage OK"
    } catch {
        Write-Log "Erreur lors du renommage : $_" "ERROR"
        Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
        exit 1
    }

    Set-ItemProperty -Path $RegPath -Name "Step" -Value 3
    Write-Log "Step mis a 3. Redemarrage dans 3 secondes..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

# ================================================================
#  ETAPE 3 - Rejoint le domaine
# ================================================================
elseif ($step -eq 3) {

    Write-Host ""
    Write-Host "=== POST-CLONAGE - Etape 3/4 : Jonction au domaine '$Domain' ===" -ForegroundColor Green
    Write-Host ""
    Write-Log "=== ETAPE 3 : Jonction au domaine '$Domain' ==="

    # Reaffirme l'autologon local (securite apres la jonction AD)
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

    Set-ItemProperty -Path $RegPath -Name "Step" -Value 4
    Write-Log "Step mis a 4. Redemarrage dans 3 secondes..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

# ================================================================
#  ETAPE 4 - Install TRMM + GPO + nettoyage
# ================================================================
elseif ($step -eq 4) {

    Write-Host ""
    Write-Host "=== POST-CLONAGE - Etape 4/4 : Installation TRMM + nettoyage ===" -ForegroundColor Green
    Write-Host ""
    Write-Log "=== ETAPE 4 : Installation de l'agent Tactical RMM ==="

    # Attente reseau (max 15 secondes)
    $apiHost = ($TRMMApi -replace "https://","")
    $X = 0
    do {
        Write-Log "Attente reseau..."
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

    # Telechargement
    Write-Log "Telechargement de l'agent..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $TRMMDownloadLink -OutFile $TempAgent -UseBasicParsing -ErrorAction Stop
    Write-Log "Telechargement OK"

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
    Write-Log "GPO synchronisees"

    # Nettoyage
    Write-Log "Nettoyage..."
    Remove-Item -Path $RegPath   -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $TempAgent -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
                        -Name "PostClone" -ErrorAction SilentlyContinue

    # Suppression du dossier script
    Write-Log "Suppression du dossier script '$ScriptFolder'..."
    Remove-Item -Path $ScriptFolder -Recurse -Force -ErrorAction SilentlyContinue

    # Desactivation de l'autologon et suppression du mot de passe local du registre
    Disable-AutoLogon

    Write-Log "=== POST-CLONAGE TERMINE === Log disponible dans $LogFile"
    Write-Host ""
    Write-Host "=== POST-CLONAGE TERMINE ===" -ForegroundColor Green
}

# ================================================================
#  ETAT INCONNU
# ================================================================
else {
    Write-Log "Valeur d'etape inconnue dans le registre ($step). Nettoyage et arret." "ERROR"
    Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
    exit 1
}

# Filet de securite global - attrape toutes les erreurs non gerees
trap {
    $errMsg = $_.Exception.Message
    $errLine = $_.InvocationInfo.ScriptLineNumber
    Write-Host "" 
    Write-Host "=== ERREUR NON GEREE (ligne $errLine) ===" -ForegroundColor Red
    Write-Host $errMsg -ForegroundColor Red
    Write-Host ""
    try { Add-Content -Path $LogFile -Value "[ERREUR NON GEREE ligne $errLine] $errMsg" } catch {}
    Write-Host "Appuyez sur Entree pour fermer..." -ForegroundColor Red
    Read-Host
    exit 1
}
