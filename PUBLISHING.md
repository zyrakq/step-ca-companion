# 🚀 Publishing Docker Images to GitHub Container Registry

## ⚡ Quick Start

### 1. 📋 Testing Before Publishing

```bash
Actions → Test Build → Run workflow
- Version: v1.0.0-test
- Branch: main/master
```

### 2. 🎯 Publishing

```bash
Actions → Release → Run workflow
- Version: v1.0.0
- Branch: main/master
- Platforms: linux/amd64,linux/arm64
```

### 3. ✅ Result

- Git tag `v1.0.0` created
- Image `ghcr.io/your-username/your-repo:1.0.0` published
- GitHub Release created

## 🐳 Using Published Image

```bash
docker run -d \
  --name my-app \
  ghcr.io/your-username/your-repo:1.0.0
```

## 🧪 Workflows

| Workflow | Purpose | When to Use | Version Format |
|----------|---------|-------------|----------------|
| **Test Build** | Build verification | Development, PR testing | `v1.0.0-test` |
| **Release** | Full publication | Official releases | `v1.0.0` |

## 🏷️ Versioning

- **v1.0.1** - 🐛 bug fixes
- **v1.1.0** - ✨ new features
- **v2.0.0** - 💥 breaking changes

### 📌 Important: Git vs Docker Tags

- **Git tags**: `v1.0.0` (with 'v' prefix)
- **Docker tags**: `1.0.0` (without 'v' prefix)

When you input `v1.0.0` in Release workflow, it creates:

- Git tag: `v1.0.0`
- Docker images: `ghcr.io/repo:1.0.0`, `ghcr.io/repo:1.0`, `ghcr.io/repo:1`

## 🔧 Configuration

- **Registry**: Uses GitHub Container Registry (ghcr.io) by default
- **Image Name**: Automatically uses repository name (`${{ github.repository }}`)
- **Permissions**: Settings → Actions → General → "Read and write permissions"

## 🔧 Troubleshooting

### ⚠️ Tag Already Exists

The workflow will fail if tag already exists. Delete the tag first:

```bash
git tag -d v1.0.0
git push origin :refs/tags/v1.0.0
```

### 🚨 Build Error

Check Actions logs and verify:

- Dockerfile syntax
- Build context
- Dependencies availability

### 🔒 Registry Access

Ensure you have access to GitHub Container Registry:

- Repository must be public or you need appropriate permissions
- GITHUB_TOKEN has necessary scopes
