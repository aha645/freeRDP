"""Stage a native client, bundle Windows runtime DLLs, and create an archive."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile

root = Path(__file__).resolve().parent.parent
prefix = Path(os.environ['PACKAGE_PREFIX']).resolve()
os_name = os.environ['PACKAGE_OS']
arch = os.environ['PACKAGE_ARCH']
name = f'freerdp-3.24.2-{os_name}-{arch}'
stage = prefix.parent / 'package' / name
if stage.exists():
    shutil.rmtree(stage)
(stage / 'bin').mkdir(parents=True)
suffix = '.exe' if os_name == 'windows' else ''
exe = stage / 'bin' / f'sdl-freerdp{suffix}'
shutil.copy2(prefix / 'bin' / exe.name, exe)

# MinGW runtime dependencies must travel with the executable. System DLLs stay
# on Windows; all DLLs found in the toolchain are copied recursively.
if os_name == 'windows':
    runtime = Path(subprocess.check_output(
        ['cygpath', '-w', os.environ['MSYSTEM_PREFIX'] + '/bin'], text=True).strip())
    candidates = {p.name.lower(): p for p in runtime.glob('*.dll')}
    candidates.update({p.name.lower(): p for p in (prefix / 'bin').glob('*.dll')})
    pending = [exe]
    copied = set()
    while pending:
        current = pending.pop()
        imports = subprocess.check_output(['objdump', '-p', str(current)], text=True)
        for dll in re.findall(r'DLL Name:\s*(\S+)', imports):
            key = dll.lower()
            if key in candidates and key not in copied:
                copied.add(key)
                dest = exe.parent / candidates[key].name
                shutil.copy2(candidates[key], dest)
                pending.append(dest)

# Refuse packages accidentally linked to the local build/install directory.
if os_name == 'macos':
    linked = subprocess.check_output(['otool', '-L', str(exe)], text=True)
    for line in linked.splitlines()[1:]:
        dep = line.strip().split(' (')[0]
        if not dep.startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError(f'Unbundled macOS dependency: {dep}')
elif os_name == 'linux':
    linked = subprocess.check_output(['ldd', str(exe)], text=True)
    if 'not found' in linked or str(prefix.parent) in linked:
        raise RuntimeError(f'Unbundled Linux dependency:\n{linked}')
    if re.search(r'lib(?:ssl|crypto|SDL3|freerdp|winpr|z\.so)', linked):
        raise RuntimeError(f'Expected static dependency linked dynamically:\n{linked}')
    (stage / 'runtime-dependencies.txt').write_text(linked)

sources = prefix.parent / 'sources'
licenses = stage / 'licenses'
shutil.copytree(prefix / 'licenses', licenses)
for project, files in {
    'FreeRDP': ['LICENSE', 'NOTICE'],
}.items():
    for file in files:
        source = sources / project / file
        if not source.exists():
            if file == 'NOTICE':
                continue
            raise FileNotFoundError(source)
        dest = licenses / project / file
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
if os_name == 'windows':
    # Include notices supplied by each MSYS2 package owning a bundled DLL.
    for dll in (stage / 'bin').glob('*.dll'):
        msys_path = subprocess.check_output(['cygpath', '-u', str(runtime / dll.name)], text=True).strip()
        owner = subprocess.check_output(['pacman', '-Qqo', msys_path], text=True).strip()
        paths = subprocess.check_output(['pacman', '-Qlq', owner], text=True).splitlines()
        for path in paths:
            if '/share/licenses/' in path and not path.endswith('/'):
                native = Path(subprocess.check_output(['cygpath', '-w', path], text=True).strip())
                dest = licenses / 'msys2' / owner / native.name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(native, dest)
shutil.copy2(root / 'README.md', stage / 'README.md')
# Exercise the staged executable; a missing DLL or invalid binary fails CI.
subprocess.run([str(exe), '/version'], check=True, timeout=60)
archive = root / 'dist' / (name + ('.zip' if os_name == 'windows' else '.tar.gz'))
if os_name == 'windows':
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for file in stage.rglob('*'):
            if file.is_file():
                output.write(file, file.relative_to(stage.parent))
else:
    with tarfile.open(archive, 'w:gz') as output:
        output.add(stage, arcname=name)
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_name(archive.name + '.sha256').write_text(f'{checksum}  {archive.name}\n')
print(archive)
