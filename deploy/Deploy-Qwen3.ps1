[CmdletBinding()]
param(
    [string]$ModelPath,
    [int]$Port = 8080,
    [int]$ContextSize = 32768,
    [int]$GpuLayers = 12,
    [int]$ParallelRequests = 1,
    [switch]$ForcePull
)

# ============================================================
# Qwen3 8B - Deploiement llama.cpp CUDA
# Infrastructure locale Forge / AfterTrace
# ============================================================

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Configuration fixe du modele et du serveur
# ------------------------------------------------------------

$modelHash = "79fa56c07429f64f41950fe2f524937cf3ae9ea9bd3d7ada72170b036ea3cc85"
$modelId = "docker.io/ai/qwen3:8B-Q4_K_M"
$image = "ghcr.io/ggml-org/llama.cpp:server-cuda"
$containerName = "qwen3-llama-server"

# Limite native connue du Qwen3 8B utilise dans ce depot.
# Une extension au-dela necessiterait une configuration RoPE adaptee.
$nativeContextLimit = 40960

$healthMaxAttempts = 60
$healthIntervalSeconds = 3

# ------------------------------------------------------------
# Fonctions utilitaires
# ------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[$Message]" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$FailureMessage
    )

    & docker @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Show-ContainerLogs {
    Write-Host ""
    Write-Host "Derniers journaux du conteneur :" -ForegroundColor Yellow
    & docker logs --tail 100 $containerName
}

# ------------------------------------------------------------
# En-tete
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "       Qwen3 - llama.cpp Server         " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 1. Resolution et validation du modele
# ------------------------------------------------------------

Write-Step "1/8 - Validation de la configuration"

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $defaultModelDir = Join-Path $env:USERPROFILE ".docker\models\bundles\sha256\$modelHash\model"
    $ModelPath = Join-Path $defaultModelDir "model.gguf"
}

if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    throw "Fichier GGUF introuvable : $ModelPath"
}

$resolvedModelPath = (Resolve-Path -LiteralPath $ModelPath).Path
$modelDir = Split-Path -Parent $resolvedModelPath
$modelFileName = Split-Path -Leaf $resolvedModelPath
$model = Get-Item -LiteralPath $resolvedModelPath

if ($Port -lt 1 -or $Port -gt 65535) {
    throw "Port invalide : $Port. La plage autorisee est 1-65535."
}

if ($ContextSize -lt 1 -or $ContextSize -gt $nativeContextLimit) {
    throw "Contexte invalide. Pour ce modele, la limite native connue est $nativeContextLimit tokens."
}

if ($GpuLayers -lt 0) {
    throw "GpuLayers ne peut pas etre negatif."
}

if ($ParallelRequests -lt 1) {
    throw "ParallelRequests doit etre au minimum de 1."
}

Write-Success "Modele trouve : $([math]::Round($model.Length / 1GB, 2)) Go"
Write-Host "Chemin modele : $resolvedModelPath"
Write-Host "Port : $Port"
Write-Host "Contexte : $ContextSize tokens"
Write-Host "Couches GPU : $GpuLayers"
Write-Host "Requetes paralleles : $ParallelRequests"

# ------------------------------------------------------------
# 2. Verification de Docker
# ------------------------------------------------------------

Write-Step "2/8 - Verification de Docker"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI est introuvable. Installe Docker Desktop ou ajoute docker au PATH."
}

& docker info *> $null

if ($LASTEXITCODE -ne 0) {
    throw "Le moteur Docker ne repond pas. Verifie que Docker Desktop est demarre."
}

Write-Success "Docker est operationnel."

# ------------------------------------------------------------
# 3. Suppression de l'ancien conteneur
# ------------------------------------------------------------

Write-Step "3/8 - Nettoyage de l'ancien conteneur"

$existing = & docker ps -aq --filter "name=^/$containerName$"

if ($LASTEXITCODE -ne 0) {
    throw "Impossible de consulter les conteneurs Docker."
}

if (-not [string]::IsNullOrWhiteSpace(($existing -join "").Trim())) {
    Write-Host "Suppression de l'ancien conteneur..." -ForegroundColor Yellow

    Invoke-Docker `
        -Arguments @("rm", "-f", $containerName) `
        -FailureMessage "Impossible de supprimer l'ancien conteneur."
}

Write-Success "Nettoyage termine."

# ------------------------------------------------------------
# 4. Verification du port
# ------------------------------------------------------------

Write-Step "4/8 - Verification du port $Port"

$listener = @(
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
)

if ($listener.Count -gt 0) {
    $processIds = $listener.OwningProcess | Sort-Object -Unique

    foreach ($processId in $processIds) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue

        if ($process) {
            Write-Host "Processus : $($process.ProcessName) (PID $processId)" -ForegroundColor Yellow
        }
    }

    throw "Le port $Port est deja utilise. Aucun processus externe ne sera arrete automatiquement."
}

Write-Success "Port disponible."

# ------------------------------------------------------------
# 5. Liberation facultative de Docker Model Runner
# ------------------------------------------------------------

Write-Step "5/8 - Liberation de la memoire GPU"

try {
    & docker model unload $modelId 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Docker Model Runner n'a pas libere le modele (peut-etre non charge ou indisponible)."
    }
    else {
        Write-Success "Modele Docker Model Runner decharge."
    }
}
catch {
    Write-Warning "Docker Model Runner indisponible ou non configure. On continue."
}

Start-Sleep -Seconds 3

# ------------------------------------------------------------
# 6. Verification de l'image
# ------------------------------------------------------------

Write-Step "6/8 - Verification de l'image llama.cpp"

& docker image inspect $image *> $null
$imageExists = ($LASTEXITCODE -eq 0)

if (-not $imageExists -or $ForcePull) {
    Write-Host "Telechargement de $image..." -ForegroundColor Yellow

    Invoke-Docker `
        -Arguments @("pull", $image) `
        -FailureMessage "Impossible de telecharger l'image llama.cpp."
}
else {
    Write-Success "Image deja presente localement. Utilise -ForcePull pour la mettre a jour."
}

# ------------------------------------------------------------
# 7. Creation du conteneur
# ------------------------------------------------------------

Write-Step "7/8 - Demarrage du serveur"

$dockerArgs = @(
    "run",
    "-d",
    "--name", $containerName,
    "--init",
    "--gpus", "all",
    "-p", "127.0.0.1:${Port}:8080",
    "--mount", "type=bind,source=$modelDir,target=/models,readonly",
    $image,
    "-m", "/models/$modelFileName",
    "--host", "0.0.0.0",
    "--port", "8080",
    "--ctx-size", "$ContextSize",
    "--n-gpu-layers", "$GpuLayers",
    "--parallel", "$ParallelRequests",
    "--jinja"
)

Invoke-Docker `
    -Arguments $dockerArgs `
    -FailureMessage "Le demarrage du conteneur a echoue."

Write-Success "Conteneur cree."

# ------------------------------------------------------------
# 8. Health check et verification de l'API
# ------------------------------------------------------------

Write-Step "8/8 - Attente du chargement du modele"

$ready = $false

for ($attempt = 1; $attempt -le $healthMaxAttempts; $attempt++) {
    try {
        $health = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$Port/health" `
            -TimeoutSec 5

        if ($health.status -eq "ok") {
            $ready = $true
            break
        }
    }
    catch {
        # Le serveur peut etre en train de charger le modele.
    }

    Write-Host "Chargement... ($attempt/$healthMaxAttempts)" -ForegroundColor Yellow
    Start-Sleep -Seconds $healthIntervalSeconds
}

if (-not $ready) {
    Write-Host "[ERREUR] Le serveur n'est pas pret." -ForegroundColor Red
    Show-ContainerLogs
    throw "Le serveur n'a pas reussi le health check."
}

Write-Success "Health check reussi."

Write-Host ""
Write-Host "Verification de l'API OpenAI..." -ForegroundColor Cyan

try {
    $models = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$Port/v1/models" `
        -TimeoutSec 10

    $serverModel = $models.data | Select-Object -First 1

    if (-not $serverModel) {
        throw "L'API n'a annonce aucun modele."
    }

    Write-Success "API OpenAI disponible."

    $actualContext = $serverModel.meta.n_ctx

    if ($null -ne $actualContext) {
        Write-Host "Contexte annonce : $actualContext tokens"

        if ([int]$actualContext -ne $ContextSize) {
            Write-Warning "Le contexte annonce ($actualContext) differe de la configuration ($ContextSize)."
        }
    }
}
catch {
    Write-Host "[ERREUR] La verification de l'API a echoue." -ForegroundColor Red
    Show-ContainerLogs
    throw
}

# ------------------------------------------------------------
# Resume
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "        Qwen3 est operationnel !        " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Host "API Base URL : http://127.0.0.1:$Port/v1"
Write-Host "Health       : http://127.0.0.1:$Port/health"
Write-Host "Web UI       : http://127.0.0.1:$Port"
Write-Host "Modele       : $($serverModel.id)"
Write-Host "Contexte     : $ContextSize tokens"
Write-Host "GPU Layers   : $GpuLayers"
Write-Host "Parallelisme : $ParallelRequests"
Write-Host ""

Write-Host "Commandes utiles :" -ForegroundColor Cyan
Write-Host "  Journaux : docker logs -f $containerName"
Write-Host "  Arreter  : docker stop $containerName"
Write-Host "  Etat     : docker stats $containerName"
Write-Host ""