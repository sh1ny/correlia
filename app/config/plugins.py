from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

_ALLOWED_PLUGIN_TYPES = frozenset({"email"})
_ALLOWED_CLASS_PREFIX = "app.plugins.outputs."
_ALLOWED_OPTION_TYPES = (str, int, float, bool, type(None))


class PluginRegistryEntry(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    name: Annotated[str, Field(min_length=1, max_length=64)]
    plugin_type: Literal["email"]
    class_path: Annotated[str, Field(min_length=1, max_length=256)]
    options: dict[str, Any] = Field(default_factory=dict, max_length=20)

    @field_validator("class_path", mode="after")
    @classmethod
    def require_trusted_class_path(cls, value: str) -> str:
        if not value.startswith(_ALLOWED_CLASS_PREFIX):
            raise ValueError("plugin class_path must live under app.plugins.outputs")
        module_name, _, class_name = value.rpartition(".")
        if module_name == _ALLOWED_CLASS_PREFIX.rstrip(".") or not class_name:
            raise ValueError("plugin class_path must include a module and class name")
        return value

    @field_validator("options", mode="after")
    @classmethod
    def validate_options(cls, value: dict[str, Any]) -> dict[str, Any]:
        for option_name, option_value in value.items():
            if not option_name or len(option_name) > 64 or option_name.startswith("__"):
                raise ValueError("plugin option names must be bounded public strings")
            _validate_option_value(option_name, option_value)
        return value


class PluginRegistryConfigFile(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    outputs: list[PluginRegistryEntry] = Field(default_factory=list, max_length=100)

    @model_validator(mode="after")
    def reject_duplicate_names(self) -> "PluginRegistryConfigFile":
        names: set[str] = set()
        for output in self.outputs:
            if output.name in names:
                raise ValueError(f"duplicate output plugin name: {output.name}")
            names.add(output.name)
        return self


@dataclass(frozen=True, slots=True)
class CompiledPluginRegistryConfig:
    outputs: tuple[PluginRegistryEntry, ...]
    config_hash: str


def load_plugin_registry_config(path: Path) -> CompiledPluginRegistryConfig:
    data = yaml.safe_load(path.read_text())
    if data is None:
        data = {"outputs": []}
    config = PluginRegistryConfigFile.model_validate(data)
    config_text = yaml.safe_dump(
        {"outputs": [entry.model_dump(mode="json") for entry in config.outputs]},
        sort_keys=True,
    )
    return CompiledPluginRegistryConfig(
        outputs=tuple(config.outputs),
        config_hash=hashlib.sha256(config_text.encode()).hexdigest(),
    )


def _validate_option_value(option_name: str, value: object) -> None:
    if isinstance(value, _ALLOWED_OPTION_TYPES):
        return
    if isinstance(value, list):
        if len(value) > 100:
            raise ValueError(f"plugin option '{option_name}' is too large")
        for item in value:
            if not isinstance(item, _ALLOWED_OPTION_TYPES):
                raise ValueError(
                    f"plugin option '{option_name}' contains an unsupported value"
                )
        return
    raise ValueError(f"plugin option '{option_name}' contains an unsupported value")
