from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = (root / 'NightwellMusic/App.swift').read_text()
views = (root / 'NightwellMusic/NativePlayerViews.swift').read_text()
assert 'struct NightwellPopup' in app
assert app.count('NightwellPopup(title:') == 5
assert 'NativeSupportView(close:' in app
assert '.fill(.ultraThinMaterial)' in app
assert 'opacity(0.98)' not in app
assert '.sheet(isPresented: $settings)' not in app
assert '.sheet(isPresented: $store.authPresented)' not in app
assert 'struct NativeSettings: View' in views
assert 'Button("Темы и ленты · Premium")' in views
assert 'Label("Воспроизведение", systemImage:' in views
assert '.nightwellLiquidGlass(22)' in views
assert 'nightwellLiquidGlass(' in app
assert 'NativeWaveSettingsView(close:' in views
assert '.sheet(isPresented: $waveSettingsPresented)' not in views
assert 'NWSourceCommit' in views
for file in (root / 'NightwellMusic').rglob('*.swift'):
    assert 'WKWebView' not in file.read_text(), file
print('Native entry point, three popup surfaces and build provenance verified')
