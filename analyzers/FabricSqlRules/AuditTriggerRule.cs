using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.SqlServer.Dac.CodeAnalysis;
using Microsoft.SqlServer.Dac.Model;

namespace FabricSqlRules
{
    /// <summary>
    /// Organization convention: a table that carries the audit columns must also have a DML
    /// trigger that populates them. DEFAULT constraints can't own the columns on UPDATE, so
    /// without a trigger the Modified* values silently go stale. Model-scoped: the Analyze
    /// method runs once and cross-checks every audited table against the triggers on it.
    /// Pairs with SR1001 (which checks the columns exist) via the shared AuditConvention.
    /// </summary>
    [ExportCodeAnalysisRule(
        RuleId,
        "Tables with audit columns must have an audit trigger.",
        Description = "Table defines the audit columns but has no AFTER INSERT, UPDATE trigger to populate them.",
        Category = "Fabric.Conventions",
        RuleScope = SqlRuleScope.Model)]
    public sealed class AuditTriggerRule : SqlCodeAnalysisRule
    {
        public const string RuleId = "Fabric.SR1002";

        public override IList<SqlRuleProblem> Analyze(SqlRuleExecutionContext context)
        {
            var problems = new List<SqlRuleProblem>();
            var model = context.SchemaModel;

            // Collect the tables that already have a trigger firing on both INSERT and UPDATE.
            var triggeredTables = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var trigger in model.GetObjects(DacQueryScopes.UserDefined, ModelSchema.DmlTrigger))
            {
                if (trigger.GetProperty<bool>(DmlTrigger.IsInsertTrigger)
                    && trigger.GetProperty<bool>(DmlTrigger.IsUpdateTrigger))
                {
                    foreach (var target in trigger.GetReferenced(DmlTrigger.TriggerObject))
                    {
                        var key = Key(target);
                        if (key != null)
                        {
                            triggeredTables.Add(key);
                        }
                    }
                }
            }

            foreach (var table in model.GetObjects(DacQueryScopes.UserDefined, ModelSchema.Table))
            {
                var key = Key(table);
                if (key != null
                    && AuditConvention.HasAllAuditColumns(table)
                    && !triggeredTables.Contains(key))
                {
                    problems.Add(new SqlRuleProblem(
                        "Table defines the audit columns but has no AFTER INSERT, UPDATE trigger to populate them.",
                        table));
                }
            }

            return problems;
        }

        private static string? Key(TSqlObject obj)
        {
            return obj.Name == null ? null : string.Join(".", obj.Name.Parts);
        }
    }
}
