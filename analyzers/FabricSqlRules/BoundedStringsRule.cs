using System.Collections.Generic;
using System.Linq;
using Microsoft.SqlServer.Dac.CodeAnalysis;
using Microsoft.SqlServer.Dac.Model;

namespace FabricSqlRules
{
    /// <summary>
    /// Organization convention: string and binary columns must declare a bounded length -
    /// no NVARCHAR(MAX) / VARCHAR(MAX) / VARBINARY(MAX). MAX columns are stored off-row, can't
    /// take part in an index key, and usually signal a modelling gap. Element-scoped: the
    /// Analyze method runs once per table.
    /// </summary>
    [ExportCodeAnalysisRule(
        RuleId,
        "String and binary columns must declare a bounded length (no MAX).",
        Description = "Column uses MAX length; declare an explicit bounded length instead.",
        Category = "Fabric.Conventions",
        RuleScope = SqlRuleScope.Element)]
    public sealed class BoundedStringsRule : SqlCodeAnalysisRule
    {
        public const string RuleId = "Fabric.SR1003";

        public BoundedStringsRule()
        {
            // Evaluate this rule once per table.
            SupportedElementTypes = new[] { ModelSchema.Table };
        }

        public override IList<SqlRuleProblem> Analyze(SqlRuleExecutionContext context)
        {
            var problems = new List<SqlRuleProblem>();
            TSqlObject table = context.ModelElement;

            foreach (var column in table.GetReferenced(Table.Columns))
            {
                // IsMax is true only for the (n)varchar(max) / varbinary(max) forms, so it is
                // a precise signal on its own - INT, NVARCHAR(200), etc. all report false.
                if (column.GetProperty<bool>(Column.IsMax))
                {
                    var columnName = column.Name.Parts.LastOrDefault();
                    problems.Add(new SqlRuleProblem(
                        $"Column [{columnName}] uses MAX length; declare an explicit bounded length instead.",
                        column));
                }
            }

            return problems;
        }
    }
}
