using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.SqlServer.Dac.CodeAnalysis;
using Microsoft.SqlServer.Dac.Model;

namespace FabricSqlRules
{
    /// <summary>
    /// Organization convention: every table must define the standard audit columns.
    /// A per-model example of a custom DacFx code-analysis rule — it runs inside
    /// `dotnet build` alongside the built-in and SqlServer.Rules rules, using the typed
    /// TSqlModel API instead of parsing model.xml by hand.
    /// </summary>
    [ExportCodeAnalysisRule(
        RuleId,
        "Tables must include the standard audit columns.",
        Description = "Every table must define CreatedAt, CreatedBy, ModifiedAt, and ModifiedBy.",
        Category = "Fabric.Conventions",
        RuleScope = SqlRuleScope.Element)]
    public sealed class AuditColumnsRule : SqlCodeAnalysisRule
    {
        public const string RuleId = "Fabric.SR1001";

        public AuditColumnsRule()
        {
            // Evaluate this rule once per table.
            SupportedElementTypes = new[] { ModelSchema.Table };
        }

        public override IList<SqlRuleProblem> Analyze(SqlRuleExecutionContext context)
        {
            var problems = new List<SqlRuleProblem>();
            TSqlObject table = context.ModelElement;

            var columnNames = table
                .GetReferenced(Table.Columns)
                .Select(c => c.Name.Parts.LastOrDefault())
                .Where(n => !string.IsNullOrEmpty(n))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            foreach (var required in AuditConvention.RequiredColumns)
            {
                if (!columnNames.Contains(required))
                {
                    problems.Add(new SqlRuleProblem(
                        $"Table is missing the required audit column [{required}].",
                        table));
                }
            }

            return problems;
        }
    }
}
