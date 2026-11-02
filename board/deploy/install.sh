#!/bin/bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then
  echo 'Run with sudo bash /path/to/install.sh' >&2
  exit 1
fi
SPEED_UPDATE_SOURCE="$(cd -- "$(dirname -- "$0")" && pwd)"
export SPEED_UPDATE_SOURCE
cd "$SPEED_UPDATE_SOURCE"
sha256sum --check SHA256SUMS
python3 - <<'PY'
from pathlib import Path
import hashlib, json, os, pwd, shutil, tempfile
from datetime import datetime
source = Path(os.environ['SPEED_UPDATE_SOURCE'])
target = Path('/home/xilinx/vib')
if not target.is_dir() or target.is_symlink():
    raise SystemExit('Existing /home/xilinx/vib directory required')
manifest = json.loads((source/'build_manifest_20261029.json').read_text())
names = list(manifest['payload_sha256']) + ['build_manifest_20261029.json']
for name, digest in manifest['payload_sha256'].items():
    if Path(name).name != name or hashlib.sha256((source/name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Invalid payload: ' + name)
for name in names:
    if (target/name).is_symlink() or ((target/name).exists() and not (target/name).is_file()):
        raise SystemExit('Ordinary target file required: ' + name)
account = pwd.getpwnam('xilinx')
stage = Path(tempfile.mkdtemp(prefix='.vib-speed-stage-',dir='/home/xilinx'))
backup = Path(tempfile.mkdtemp(prefix='vib_speed_backup_'+datetime.now().strftime('%Y%m%d_%H%M%S')+'_',dir='/home/xilinx'))
replaced = []
try:
    for name in names:
        shutil.copyfile(source/name,stage/name)
        os.chmod(stage/name,0o755 if name.endswith('.sh') else 0o644)
        os.chown(stage/name,account.pw_uid,account.pw_gid)
        if (target/name).exists():
            shutil.copy2(target/name,backup/name)
    for name in names:
        os.replace(stage/name,target/name)
        replaced.append(name)
except BaseException:
    for name in reversed(replaced):
        if (backup/name).exists():
            os.replace(backup/name,target/name)
        else:
            (target/name).unlink()
    raise
finally:
    shutil.rmtree(stage)
print('PROGRAM UPDATE: PASS ->',target)
print('PREVIOUS PROGRAM FILES:',backup)
print('Existing logs were preserved. Starting motor-OFF system check.',flush=True)
PY
sync
bash /home/xilinx/vib/run_system_check.sh
