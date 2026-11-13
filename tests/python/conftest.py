"""The first boot program and the serve script are files of the overlay,
not packages. Each one is loaded under a name of its own."""
import importlib.machinery
import importlib.util
import os

import pytest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
HOOK = os.path.join(ROOT, "overlay", "usr", "lib", "inithooks", "bin", "nodebb.py")
SERVE = os.path.join(ROOT, "overlay", "usr", "lib", "keel-nodebb", "serve.py")


def _load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def hook():
    return _load("keel_nodebb_hook", HOOK)


@pytest.fixture(scope="session")
def serve():
    return _load("keel_nodebb_serve", SERVE)
