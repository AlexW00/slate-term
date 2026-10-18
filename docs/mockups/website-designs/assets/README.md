# Website app icon

`app-icon.png` is a 256-pixel PNG export of `Contents/Resources/AppIcon.icns` from the signed Slate Terminal 0.1.0 app. It preserves the shipped artwork and transparency. The source icon lives in `slate-term/AppIcon.icon`.

To refresh after an icon change, export the built app’s icon with macOS `sips`:

```sh
sips -s format png -Z 256 '/path/to/Slate Terminal.app/Contents/Resources/AppIcon.icns' --out docs/mockups/website-designs/assets/app-icon.png
```

Review the website in desktop/mobile and light/dark appearances after refreshing. The Pages workflow copies this directory beside `index.html`.
