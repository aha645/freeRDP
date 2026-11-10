"""Create a reusable SDK before installing FreeRDP into the same prefix."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

root = Path(__file__).resolve().parent.parent
prefix = Path(os.environ['PACKAGE_PREFIX']).resolve()
name = f'freerdp-deps-{os.environ["PACKAGE_OS"]}-{os.environ["PACKAGE_ARCH"]}'
licenses = prefix / 'licenses'
sources = prefix.parent / 'sources'
for project, files in {
    'openssl': ['LICENSE.txt'], 'zlib': ['LICENSE'], 'SDL': ['LICENSE.txt'],
    'SDL_ttf': ['LICENSE.txt', 'external/freetype/LICENSE.TXT',
                'external/freetype/docs/FTL.TXT', 'external/freetype/docs/GPLv2.TXT'],
}.items():
    for file in files:
        dest = licenses / project / file
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sources / project / file, dest)
metadata = {
    'platform': os.environ['PACKAGE_OS'], 'architecture': os.environ['PACKAGE_ARCH'],
    'compiler': subprocess.check_output([os.environ.get('CC', 'cc'), '--version'], text=True),
    'system': subprocess.check_output(['uname', '-a'], text=True).strip(),
    'versions': {'openssl': '3.5.0', 'zlib': '1.3.1', 'SDL': '3.2.28', 'SDL_ttf': '3.2.2'},
    'linkage': 'static (OS and compiler runtime libraries remain external)',
}
(prefix / 'sdk.json').write_text(json.dumps(metadata, indent=2) + '\n')
archive = root / 'dist' / (name + '.tar.gz')
with tarfile.open(archive, 'w:gz') as output:
    def static_sdk(info):
        relative = Path(info.name).relative_to(name)
        # OpenSSL CLI and zlib's incidental shared build are not SDK inputs.
        if relative.parts and relative.parts[0] == 'bin':
            return None
        if '.so' in relative.name or relative.name.endswith(('.dylib', '.dll', '.dll.a')):
            return None
        return info
    output.add(prefix, arcname=name, filter=static_sdk)
archive.with_name(archive.name + '.sha256').write_text(
    f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n')
print(archive)
