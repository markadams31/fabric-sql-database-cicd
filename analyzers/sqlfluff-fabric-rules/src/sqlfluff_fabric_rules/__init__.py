"""SQLFluff plugin: custom style rules for the Fabric SQL reference solution.

The source-text (SQLFluff) counterpart to the model-level DacFx rules in
``analyzers/FabricSqlRules``. SQLFluff discovers this plugin through the ``sqlfluff``
entry point declared in ``pyproject.toml`` once the package is installed.
"""

from sqlfluff.core.plugin import hookimpl


@hookimpl
def get_rules():
    """Return the custom rules this plugin contributes to SQLFluff."""
    # Imported inside the hook (not at module load) so SQLFluff's plugin machinery is fully
    # initialised before the rule classes are constructed — the documented plugin pattern.
    from sqlfluff_fabric_rules.rules import Rule_Fabric_L001

    return [Rule_Fabric_L001]
