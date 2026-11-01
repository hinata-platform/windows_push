# Releasing

```sh
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/publish.yml` publishes the package when its pubspec carries
the tag's version.

## One-time setup

1. Publish it once by hand (`flutter pub publish`), because pub.dev's
   automated-publishing settings exist only after the first upload.
2. On pub.dev: Admin → Automated publishing → GitHub Actions, repository
   `hinata-platform/windows_push`, tag pattern `v{{version}}`.
3. Transfer it to the `ahmadre.com` publisher.
