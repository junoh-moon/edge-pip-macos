from pathlib import Path
import json
import os
import sys
import tempfile

extension = (Path(__file__).parent / 'extension-id').read_text().strip()
origins = [f'chrome-extension://{extension}/']
relay = Path(sys.argv[1]).resolve()
folder = Path.home() / 'Library/Application Support/Microsoft Edge/NativeMessagingHosts'
folder.mkdir(parents=True, exist_ok=True)
for name, executable, description in [
    ('local.edgepip.controls', relay, 'Controls for the video opened in Edge picture in picture'),
    ('local.edgepip.protection', relay.with_name('EdgePiPGuard'), 'Pause local PiP capture during protected playback'),
]:
    assert executable.is_file()
    path = folder / (name + '.json')
    value = dict(name=name, path=str(executable), description=description, type='stdio', allowed_origins=origins)
    if path.exists():
        existing = json.loads(path.read_text())
        assert existing['name'] == name and existing['allowed_origins'] == origins
        if existing == value:
            continue
    with tempfile.NamedTemporaryFile(mode='w', dir=folder, delete=False) as file:
        json.dump(value, file, indent=2)
        temporary = file.name
    os.replace(temporary, path)
