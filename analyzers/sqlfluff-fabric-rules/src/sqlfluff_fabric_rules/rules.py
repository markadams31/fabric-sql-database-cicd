"""Custom SQLFluff rules for the Fabric SQL reference solution."""

from sqlfluff.core.rules import BaseRule, LintResult, RuleContext
from sqlfluff.core.rules.crawlers import SegmentSeekerCrawler


class Rule_Fabric_L001(BaseRule):
    """String literals should be Unicode (prefixed with ``N``).

    This platform is Entra/Unicode-first and every character column in the reference schema
    is ``NVARCHAR``. Comparing or assigning a non-Unicode literal (``'x'``) to an ``NVARCHAR``
    forces an implicit conversion — and when the literal meets an indexed ``NVARCHAR`` column
    in a predicate, that conversion can turn a seek into a scan. Prefix string literals with
    ``N`` so the literal is Unicode from the start.

    This is the SQLFluff (source-text) counterpart to the model-level DacFx rules in
    ``analyzers/FabricSqlRules`` — a worked example of adding a project-specific style rule.

    **Anti-pattern**

    A bare string literal:

    .. code-block:: sql

        CONSTRAINT [CK_Order_Status] CHECK ([Status] IN ('Pending', 'Paid'));

    **Best practice**

    Prefix it with ``N``:

    .. code-block:: sql

        CONSTRAINT [CK_Order_Status] CHECK ([Status] IN (N'Pending', N'Paid'));
    """

    name = "fabric.unicode_string_literals"
    # In the "all" group so it runs with the default rule set. Give it a short alias too.
    groups = ("all", "fabric")
    aliases = ("FAB01",)
    # Only visit string literals; numeric, binary, and other literals are left alone.
    crawl_behaviour = SegmentSeekerCrawler({"quoted_literal"})

    def _eval(self, context: RuleContext):
        raw = context.segment.raw
        # A national (Unicode) literal begins with N'...'; a plain string literal begins with
        # a quote. Flag only the plain form, so 'x' is caught and N'x' passes.
        if raw[:1] == "'":
            return LintResult(
                anchor=context.segment,
                description="String literal is not Unicode; prefix it with N (e.g. N'text').",
            )
        return None
