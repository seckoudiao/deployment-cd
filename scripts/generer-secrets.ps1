# Genere secrets.env avec des valeurs aleatoires (Windows PowerShell 5.1 ou PowerShell 7).
# Usage, depuis le dossier deployment-cd :
#   powershell -ExecutionPolicy Bypass -File scripts\generer-secrets.ps1
# Le fichier n'est jamais ecrase : supprimez-le d'abord pour en generer un nouveau
# (et supprimez aussi les donnees : docker compose ... down -v, car MySQL garde ses anciens mots de passe).

$ErrorActionPreference = 'Stop'
$cible = Join-Path (Split-Path $PSScriptRoot -Parent) 'secrets.env'

if (Test-Path $cible) {
    Write-Host "secrets.env existe deja : rien n'est modifie." -ForegroundColor Yellow
    exit 0
}

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
function Hex([int]$octets) {
    $b = New-Object byte[] $octets; $rng.GetBytes($b)
    -join ($b | ForEach-Object { $_.ToString('x2') })
}
function Base64([int]$octets) {
    $b = New-Object byte[] $octets; $rng.GetBytes($b)
    [Convert]::ToBase64String($b)
}

$motDePasseAdmin = Hex 8   # 16 caracteres, affiche une seule fois ci-dessous

$lignes = @(
    "MYSQL_ROOT_PASSWORD=$(Hex 16)",
    "DB_PASSWORD=$(Hex 16)",
    "JWT_SECRET=$(Base64 48)",
    "INTERNAL_API_KEY=$(Hex 32)",
    "MINIO_ROOT_PASSWORD=$(Hex 16)",
    "BOOTSTRAP_ADMIN_PASSWORD=$motDePasseAdmin"
)
# UTF-8 sans BOM et fins de ligne LF : lu correctement par Docker Compose
[IO.File]::WriteAllText($cible, ($lignes -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))

Write-Host "secrets.env cree." -ForegroundColor Green
Write-Host ""
Write-Host "Compte administrateur de VOTRE installation :"
Write-Host "  email        : admin@uadb.edu.sn"
Write-Host "  mot de passe : $motDePasseAdmin" -ForegroundColor Cyan
Write-Host "Notez-le maintenant : il ne sera plus affiche (il est aussi dans secrets.env)."
