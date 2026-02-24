// src/plugins/core/constants.ts
var CORE_PLUGIN_NAME = "core", SERVICE_ENTRY = `${CORE_PLUGIN_NAME}:entry`, SERVICE_LOCAL_EXPLORER = `${CORE_PLUGIN_NAME}:local-explorer`, LOCAL_EXPLORER_DISK = `${CORE_PLUGIN_NAME}:local-explorer-disk`, LOCAL_EXPLORER_BASE_PATH = "/cdn-cgi/explorer", LOCAL_EXPLORER_API_PATH = `${LOCAL_EXPLORER_BASE_PATH}/api`, SERVICE_USER_PREFIX = `${CORE_PLUGIN_NAME}:user`, SERVICE_BUILTIN_PREFIX = `${CORE_PLUGIN_NAME}:builtin`, SERVICE_CUSTOM_FETCH_PREFIX = `${CORE_PLUGIN_NAME}:custom-fetch`, SERVICE_CUSTOM_NODE_PREFIX = `${CORE_PLUGIN_NAME}:custom-node`;
var INTROSPECT_SQLITE_METHOD = "__miniflare_introspectSqlite";

// src/workers/core/do-wrapper.worker.ts
function createDurableObjectWrapper(UserClass) {
  class Wrapper extends UserClass {
    constructor(ctx, env) {
      super(ctx, env);
    }
    /**
     * Execute SQL queries against the DO's SQLite storage.
     * If multiple queries are provided, they run in a transaction.
     */
    [INTROSPECT_SQLITE_METHOD](queries) {
      let sql = this.ctx.storage.sql;
      if (!sql)
        throw new Error(
          "This Durable Object does not have SQLite storage enabled"
        );
      let executeQuery = (query) => {
        let cursor = sql.exec(query.sql, ...query.params ?? []);
        return {
          columns: cursor.columnNames,
          rows: Array.from(cursor.raw()),
          meta: {
            rows_read: cursor.rowsRead,
            rows_written: cursor.rowsWritten
          }
        };
      }, results = [];
      return queries.length > 1 ? this.ctx.storage.transactionSync(() => {
        for (let query of queries)
          results.push(executeQuery(query));
      }) : results.push(executeQuery(queries[0])), results;
    }
  }
  return Object.defineProperty(Wrapper, "name", { value: UserClass.name }), Wrapper;
}
export {
  createDurableObjectWrapper
};
//# sourceMappingURL=do-wrapper.worker.js.map
