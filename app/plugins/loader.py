from __future__ import annotations

import importlib
from pathlib import Path
from types import ModuleType
from typing import Any, Literal, cast

from app.config.plugins import PluginRegistryEntry, load_plugin_registry_config
from app.plugins.interfaces import OutputPlugin, PluginStatus

_ALLOWED_CLASS_PREFIX = "app.plugins.outputs."
PluginCategory = Literal["email", "unknown"]
_PLUGIN_CATEGORIES = frozenset(("email", "unknown"))
_READINESS_PLUGIN_CATEGORIES = ("email",)
PluginStartupFailureCode = Literal[
    "registry_entry", "module_or_class", "interface", "constructor", "status"
]


class PluginStartupError(ValueError):
    """Redacted, finite eager-registry failure propagated to lifespan."""

    def __init__(
        self,
        category: PluginCategory,
        failure_code: PluginStartupFailureCode,
        entry_position: int,
    ) -> None:
        self.category = category if category in _PLUGIN_CATEGORIES else "unknown"
        self.failure_code = failure_code
        self.entry_position = entry_position
        super().__init__(f"plugin registry startup failed at entry #{entry_position}")


class PluginRegistry:
    def __init__(
        self, entries: tuple[PluginRegistryEntry, ...], config_hash: str
    ) -> None:
        self._entries = {entry.name: entry for entry in entries}
        self._entry_positions = {
            entry.name: position for position, entry in enumerate(entries, start=1)
        }
        self.config_hash = config_hash
        self._plugins: dict[str, OutputPlugin] = {}
        for name in self._entries:
            plugin = self.get_plugin(name)
            position = self._entry_positions[name]
            category = _plugin_category(self._entries[name])
            try:
                status = plugin.plugin_status()
            except Exception:
                raise PluginStartupError(category, "status", position) from None
            if not isinstance(status, PluginStatus):
                raise PluginStartupError(category, "status", position)

    def get_plugin(self, name: str) -> OutputPlugin:
        plugin = self._plugins.get(name)
        if plugin is not None:
            return plugin
        entry = self._entries.get(name)
        if entry is None:
            raise KeyError(f"unknown output plugin: {name}")
        plugin = _instantiate_plugin(entry, self._entry_positions[name])
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
                }
            )
        return tuple(rows)

    def readiness_states(self) -> dict[str, str]:
        """Return one secret-free readiness state for every fixed output category."""
        states = {
            category: "not_configured" for category in _READINESS_PLUGIN_CATEGORIES
        }
        for name, entry in self._entries.items():
            category = _plugin_category(entry)
            if category not in states or states[category] == "not_ready":
                continue
            try:
                status = self.get_plugin(name).plugin_status()
            except Exception:
                states[category] = "not_ready"
                continue
            if not isinstance(status, PluginStatus) or status.ready is not True:
                states[category] = "not_ready"
            elif states[category] == "not_configured":
                states[category] = "ready"
        return states

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(sorted(self._entries))

    @property
    def categories(self) -> tuple[PluginCategory, ...]:
        return tuple(_plugin_category(entry) for entry in self._entries.values())


def load_plugin_registry(path: Path) -> PluginRegistry:
    try:
        config = load_plugin_registry_config(path)
    except Exception:
        raise PluginStartupError("unknown", "registry_entry", 0) from None
    return PluginRegistry(config.outputs, config.config_hash)


def _instantiate_plugin(entry: PluginRegistryEntry, position: int) -> OutputPlugin:
    category = _plugin_category(entry)
    module_name, _, class_name = entry.class_path.rpartition(".")
    if not module_name.startswith(_ALLOWED_CLASS_PREFIX):
        raise PluginStartupError(category, "module_or_class", position)
    try:
        module = importlib.import_module(module_name)
        cls = _get_plugin_class(module, class_name)
    except Exception:
        raise PluginStartupError(category, "module_or_class", position) from None
    try:
        instance = cls(**entry.options)
    except Exception:
        raise PluginStartupError(category, "constructor", position) from None
    if not callable(getattr(instance, "send_notification", None)) or not callable(
        getattr(instance, "plugin_status", None)
    ):
        raise PluginStartupError(category, "interface", position)
    return cast(OutputPlugin, instance)


def _get_plugin_class(module: ModuleType, class_name: str) -> type[Any]:
    candidate = getattr(module, class_name, None)
    if candidate is None:
        raise ValueError(f"missing output plugin class: {class_name}")
    if not isinstance(candidate, type):
        raise ValueError(f"output plugin target is not a class: {class_name}")
    return candidate


def _plugin_category(entry: PluginRegistryEntry) -> PluginCategory:
    return entry.plugin_type if entry.plugin_type in _PLUGIN_CATEGORIES else "unknown"
