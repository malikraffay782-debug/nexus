# Project mount + real Run (Phase 2)

## Design

```
host (Android)                                   guest (proot)
<documents>/projects/<id>/   ── -b ──►           /home/project/
   src/main.py                                   src/main.py
```

- Flutter sends only `projectId`.
- Kotlin resolves `context.getDir("flutter")/projects/<id>` (path_provider documents).
- proot: `-b <host>:/home/project -w /home/project`
- Guest argv: `env PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 python3 /home/project/src/main.py`

## Device checks

1. Initialize runtime; `pkg install python` if needed.
2. Create project → Run → expect Hello / print from main.py.
3. Edit main.py → Run again.
4. Delete main.py → clear error.
