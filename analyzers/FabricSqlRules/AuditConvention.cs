using System;
using System.Linq;
using Microsoft.SqlServer.Dac.Model;

namespace FabricSqlRules
{
    /// <summary>
    /// The audit-column convention, shared by the rules that enforce it (SR1001 checks the
    /// columns exist, SR1002 checks they're trigger-populated) so their idea of "the audit
    /// columns" can never drift apart. This is the single place those names live.
    /// </summary>
    internal static class AuditConvention
    {
        // Your organization's audit columns. This is the adaptation point - change these names
        // (both rules and the demo triggers read from the same convention) to make it yours.
        public static readonly string[] RequiredColumns =
            { "CreatedAt", "CreatedBy", "ModifiedAt", "ModifiedBy" };

        /// <summary>True if the table defines every audit column.</summary>
        public static bool HasAllAuditColumns(TSqlObject table)
        {
            var columnNames = table
                .GetReferenced(Table.Columns)
                .Select(c => c.Name.Parts.LastOrDefault())
                .Where(n => !string.IsNullOrEmpty(n))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);

            return RequiredColumns.All(columnNames.Contains);
        }
    }
}
