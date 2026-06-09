from __future__ import annotations

import importlib
from pathlib import Path
from types import ModuleType
from typing import Any, cast

from app.config.plugins import PluginRegistryEntry, load_plugin_registry_config
from app.plugins.interfaces import OutputPlugin

_ALLOWED_CLASS_PREFIX = "app.plugins.outputs."


class PluginRegistry:
    def __init__(self, entries: tuple[PluginRegistryEntry, ...], config_hash: str) -> None:
        self._entries = {entry.name: entry for entry in entries}
        self.config_hash = config_hash
        self._plugins: dict[str, OutputPlugin] = {}
        for name in self._entries:
            self.get_plugin(name)

    def get_plugin(self, name: str) -> OutputPlugin:
        plugin = self._plugins.get(name)
        if plugin is not None:
            return plugin
        entry = self._entries.get(name)
        if entry is None:
            raise KeyError(f"unknown output plugin: {name}")
        plugin = _instantiate_plugin(entry)
        self._plugins[name] = plugin
        return plugin

    def list_plugins(self) -> tuple[dict[str, object], ...]:
        rows: list[dict[str, object]] = []
        for name in sorted(self._entries):
            entry = self._entries[name]
            status = self.get_plugin(name).plugin_status()
            rows.append(
                {
                    "name": name,
                    "plugin_type": entry.plugin_type,
                    "status": status.status,
                    "ready": status.ready,
                    "config_hash": self.config_hash,
                }
            )
        return tuple(rows)

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(sorted(self._entries))


def load_plugin_registry(path: Path) -> PluginRegistry:
    config = load_plugin_registry_config(path)
    return PluginRegistry(config.outputs, config.config_hash)


def _instantiate_plugin(entry: PluginRegistryEntry) -> OutputPlugin:
    module_name, _, class_name = entry.class_path.rpartition(".")
    if not module_name.startswith(_ALLOWED_CLASS_PREFIX):
        raise ValueError("plugin module must live under app.plugins.outputs")
    module = importlib.import_module(module_name)
    cls = _get_plugin_class(module, class_name)
    instance = cls(**entry.options)
    if not callable(getattr(instance, "send_notification", None)) or not callable(
        getattr(instance, "plugin_status", None)
    ):
        raise ValueError(f"{entry.class_path} does not implement OutputPlugin")
    return cast(OutputPlugin, instance)


def _get_plugin_class(module: ModuleType, class_name: str) -> type[Any]:
    candidate = getattr(module, class_name, None)
    if candidate is None:
        raise ValueError(f"missing output plugin class: {class_name}")
    if not isinstance(candidate, type):
        raise ValueError(f"output plugin target is not a class: {class_name}")
    return candidate
