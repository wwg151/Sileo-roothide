# Sileo-roothide

- Work on `dev`; fetch before editing or pushing. Preserve `dev-1`.
- Build Swift/Xcode code on GitHub Actions, not on this device. Pushes to `dev` trigger `.github/workflows/build.yml` with Xcode 27.1.
- Distribution packages come from `apelin/build.sh`, declared in `apelin-project.json`: it selects the newest matching `dl/*_<architecture>.deb` by modification time and repackages it with this project's identity and `layout/version`. Roothide requires `iphoneos-arm64e` and an empty prefix; rootless requires `iphoneos-arm64` and `/var/jb`. An explicit `SILEO_INPUT_DEB` overrides selection, but must match the target architecture and app layout. The script preserves the compiled payload; it does not compile Swift or convert binaries between bootstraps.
- The current CI below only produces roothide. For rootless packaging, first supply a genuine rootless build in `dl/` (the Makefile target is `SILEO_PLATFORM=iphoneos-arm64`). Rootless compilation and device compatibility still need verification.
- CI first runs `bash Scripts/test-functional-search.sh` against the production Foundation search core, then builds `make clean package DEBUG=0 ALL_BOOTSTRAPS=1 SILEO_PLATFORM=iphoneos-arm64e V=1`.
- CI publishes the roothide package and SHA256SUMS under release `roothide-dev`. Deployment to `wwg151/repo` is enabled in build.yml after the user confirmed the download/queue redesign is stable. Keep existing packages; do not add cleanup commands. Preserve remote `dev-2`, the pre-redesign backup.
- Poll the release checksum with `icli probe dl/poll_release.js` in short intervals. Download using `icli probe dl/probe_dl_deb.js`, verify SHA256SUMS, then deliver with file_show. Do not install for the user.
- Search uses package metadata plus readable native depiction text captured when viewed. Test Chinese/English concepts, natural phrases, package names/IDs, typos, ranking, detail-only matches, and recycled-cell highlighting. HTML/image-only depictions are not indexed.
- After installation by the user, verify functional search and highlight appearance on the device. CI checks do not prove UI behavior or real repository coverage.
- Put user-facing strings in Base.lproj and zh-Hans.lproj. Use 插件包 for package and 插件 for software.
