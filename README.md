# IA Local Server

Deployment scripts for running **Qwen3 8B (GGUF)** locally with **llama.cpp CUDA Server** on Windows and Docker Desktop.

The project is intentionally standalone: it deploys one local inference server and exposes an OpenAI-compatible API on the host machine.

## Features

- Runs `llama.cpp` using its CUDA server image.
- Mounts the GGUF model read-only.
- Binds the API to `127.0.0.1` only.
- Supports configurable context size, GPU layers, host port and request parallelism.
- Uses one parallel request by default to reduce memory pressure.
- Checks Docker, the model file, the listening port, server health and the OpenAI-compatible models endpoint.
- Keeps the model file outside the Git repository.

## Requirements

- Windows 10/11
- PowerShell 5.1 or later
- Docker Desktop with the Linux container engine
- NVIDIA GPU with working Docker GPU passthrough
- A compatible NVIDIA driver
- The Qwen3 8B GGUF model

The default model path is the Docker Model Runner bundle path used by the original deployment:

```text
%USERPROFILE%\.docker\models\bundles\sha256\79fa56c07429f64f41950fe2f524937cf3ae9ea9bd3d7ada72170b036ea3cc85\model\model.gguf
```

The script does not download the GGUF model. Supply the model separately.

## Repository layout

```text
IA-local-server/
├── deploy/
│   └── Deploy-Qwen3.ps1
├── .gitignore
└── README.md
```

## Quick start

Clone the repository:

```powershell
git clone https://github.com/CrowTheFallen/IA-local-server.git
cd IA-local-server
```

Run the deployment script:

```powershell
.\deploy\Deploy-Qwen3.ps1
```

If PowerShell blocks script execution for the current session, use:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\deploy\Deploy-Qwen3.ps1
```

## Configuration

The script exposes the most useful deployment settings as parameters.

| Parameter | Default | Description |
|---|---:|---|
| `-ModelPath` | Docker Model Runner bundle path | Full path to the GGUF file |
| `-Port` | `8080` | Host port |
| `-ContextSize` | `32768` | Server context size in tokens |
| `-GpuLayers` | `12` | Number of model layers offloaded to the GPU |
| `-ParallelRequests` | `1` | Number of concurrent server slots |
| `-ForcePull` | Off | Pull the latest image tag even if it exists locally |

Examples:

Use a different GGUF file:

```powershell
.\deploy\Deploy-Qwen3.ps1 -ModelPath "D:\Models\Qwen3-8B-Q4_K_M.gguf"
```

Use a smaller context:

```powershell
.\deploy\Deploy-Qwen3.ps1 -ContextSize 16384
```

Pull the latest llama.cpp server image:

```powershell
.\deploy\Deploy-Qwen3.ps1 -ForcePull
```

Change the host port and GPU offload:

```powershell
.\deploy\Deploy-Qwen3.ps1 -Port 8081 -GpuLayers 20
```

## API endpoints

Once the health check succeeds:

| Endpoint | Purpose |
|---|---|
| `http://127.0.0.1:8080/v1` | OpenAI-compatible API base URL |
| `http://127.0.0.1:8080/v1/models` | List loaded models |
| `http://127.0.0.1:8080/health` | Server health |
| `http://127.0.0.1:8080` | llama.cpp web interface, if enabled by the image |

For OpenChamber/OpenCode, configure an OpenAI-compatible provider with:

- Base URL: `http://localhost:8080/v1`
- Model ID: use the ID returned by `/v1/models`
- API key: use a placeholder such as `local` if the client requires a value

## Operations

Follow server logs:

```powershell
docker logs -f qwen3-llama-server
```

Stop the server:

```powershell
docker stop qwen3-llama-server
```

Start an existing stopped container:

```powershell
docker start qwen3-llama-server
```

Inspect resource usage:

```powershell
docker stats qwen3-llama-server
```

Inspect the last container state:

```powershell
docker inspect qwen3-llama-server --format 'OOMKilled={{.State.OOMKilled}} | ExitCode={{.State.ExitCode}}'
```

## Memory and context notes

The default context size is **32,768 tokens**. This is a configuration target, not a guarantee that the host has enough RAM or VRAM to sustain it.

The script defaults to one parallel request to limit simultaneous context/KV-cache allocations. Increasing context size or parallelism can substantially increase memory consumption. If the container exits with code `137` or `OOMKilled=true`, reduce context size and/or GPU offload, then inspect both Docker and host memory usage.

The script validates the configured context against the known native context limit of **40,960 tokens** for the Qwen3 8B model targeted here. It does not attempt RoPE scaling or context extension beyond the model's native limit.

## Network exposure

The Docker port is deliberately published on `127.0.0.1`, not `0.0.0.0`. This keeps the service bound to the local host interface by default.

Do not expose this inference endpoint to a LAN, VPN or public network without first adding appropriate authentication, access controls and transport security.

## Troubleshooting

### Docker is unavailable

Start Docker Desktop and confirm the Linux container engine is running:

```powershell
docker info
```

### The port is already in use

Find the process listening on the configured port:

```powershell
Get-NetTCPConnection -LocalPort 8080 -State Listen |
    Select-Object LocalAddress, LocalPort, OwningProcess
```

The deployment script does not terminate unrelated processes automatically.

### The container exits with code 137

Check whether Docker reports an OOM kill:

```powershell
docker inspect qwen3-llama-server --format 'OOMKilled={{.State.OOMKilled}} | ExitCode={{.State.ExitCode}}'
```

Then inspect logs and reduce memory requirements:

```powershell
docker logs --tail 150 qwen3-llama-server
.\deploy\Deploy-Qwen3.ps1 -ContextSize 16384
```

### The API is healthy but the model list is empty

Inspect the server logs:

```powershell
docker logs --tail 150 qwen3-llama-server
```

Confirm that the GGUF file is readable and that the container was created with the expected model mount.

## Versioning

The deployment uses the `ghcr.io/ggml-org/llama.cpp:server-cuda` image tag. For reproducible deployments, consider pinning a specific image version or digest after validating it.

## License

No license is currently included. Public visibility on GitHub does not, by itself, grant permission to reuse, modify or redistribute this project. Add a license explicitly if you want to grant those rights.
