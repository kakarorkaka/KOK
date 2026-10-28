# 打包与发布 DMG

> 二进制不提交进 git。用 **GitHub Releases** 放 DMG：仓库历史保持干净，下载链接稳定，
> 也不会把旧版本 `.app` 塞进每次 clone。

## 1. 构建

```bash
./scripts/build-dmg.sh
```

产物：`build/release/KoK-<version>.dmg`（`build/` 已 gitignore）。

脚本会：

- 构建 universal（arm64 + x86_64）Release；
- 优先用本机 `Developer ID Application: Kakar Zhang (KXWXY96P85)` 签名；
- 没有 Developer ID 时退化 ad-hoc（只适合本机测试）；
- 创建带 `Applications` 快捷方式的 DMG。

## 2. 公证（让别人双击就能开）

没有公证的包，下载后会被 Gatekeeper 标记；用户需要右键 →「打开」。
真正的「直接打开」需要 Developer ID 签名 + notarization。

### 2.1 存一次凭据

用 App Store Connect 的 **app-specific password**（不是 Apple ID 密码）：

```bash
xcrun notarytool store-credentials KoKNotary \
  --apple-id "you@example.com" \
  --team-id "KXWXY96P85" \
  --password "<app-specific-password>"
```

也可以换用 App Store Connect API Key（`--key --key-id --issuer`），见
`xcrun notarytool store-credentials --help`。

### 2.2 带公证构建

```bash
NOTARY_PROFILE=KoKNotary ./scripts/build-dmg.sh
```

脚本会 `notarytool submit --wait`，然后 `stapler staple` + `stapler validate`。
成功后：

```bash
spctl --assess --type execute --verbose=4 \
  build/release-dd/Build/Products/Release/KoK.app
```

应显示 `accepted` / `source=Notarized Developer ID`。

## 3. 发布到 GitHub Releases

```bash
git tag v5.2
git push origin v5.2

gh release create v5.2 build/release/KoK-5.2.dmg \
  --title "KoK 5.2" \
  --notes-file docs/release-notes-5.2.md
```

README 的「下载」指向：

```text
https://github.com/kakarorkaka/KOK/releases
```

## 4. 如果暂时没有公证凭据

可以发布，但 release notes 必须写清楚：

- 已用 Developer ID 签名；
- **未公证**；
- 首次打开：右键 App →「打开」，或「系统设置 ▸ 隐私与安全性」→「仍要打开」；
- 不要建议用户全局关闭 Gatekeeper。

## 5. 以后自动化

GitHub Actions 的 macOS runner 可以跑同一份 `scripts/build-dmg.sh`，但需要把
Developer ID 证书（.p12）和 notary 凭据放进 Repository Secrets。没有这些 secrets 时，
CI 只能产出 ad-hoc 包，不适合公开发布。当前先本地构建、手动上传。
