"""mocode-cli CLI - Manage your mocode-cli from the command line."""

import os as _os

def _read_version():
    version_file = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "VERSION")
    try:
        with open(version_file, "r") as f:
            return f.read().strip()
    except FileNotFoundError as e:
        return "0.0.0"

__version__ = _read_version()