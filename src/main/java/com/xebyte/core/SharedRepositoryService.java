package com.xebyte.core;

import com.xebyte.headless.GhidraServerManager;

/**
 * MCP tools for interacting with a shared Ghidra Server (repository).
 * Wraps {@link GhidraServerManager} — exposes the real (non-stub) operations
 * as discoverable MCP endpoints for both GUI and headless modes.
 */
@McpToolGroup(value = "server", description = "Shared Ghidra Server — connect, browse repositories, version history, admin")
public class SharedRepositoryService {

    private final GhidraServerManager serverManager;

    public SharedRepositoryService(GhidraServerManager serverManager) {
        this.serverManager = serverManager;
    }

    // ========================================================================
    // Connection
    // ========================================================================

    @McpTool(path = "/server/connect", method = "POST",
        description = "Connect to a shared Ghidra Server. Credentials are read from env vars "
            + "GHIDRA_SERVER_HOST (default localhost), GHIDRA_SERVER_PORT (default 13100), "
            + "GHIDRA_SERVER_USER, GHIDRA_SERVER_PASSWORD.",
        category = "server")
    public Response serverConnect() {
        return Response.text(serverManager.connect());
    }

    @McpTool(path = "/server/disconnect", method = "POST",
        description = "Disconnect from the shared Ghidra Server.",
        category = "server")
    public Response serverDisconnect() {
        return Response.text(serverManager.disconnect());
    }

    @McpTool(path = "/server/status",
        description = "Check Ghidra Server connection status, credentials config, and last error.",
        category = "server")
    public Response serverStatus() {
        return Response.text(serverManager.getStatus());
    }

    // ========================================================================
    // Repository browsing
    // ========================================================================

    @McpTool(path = "/server/repositories",
        description = "List all repositories on the connected Ghidra Server.",
        category = "server")
    public Response listRepositories() {
        return Response.text(serverManager.listRepositories());
    }

    @McpTool(path = "/server/repository/files",
        description = "List files and folders in a repository path.",
        category = "server")
    public Response listRepositoryFiles(
            @Param(value = "repo", description = "Repository name") String repo,
            @Param(value = "path", defaultValue = "/", description = "Folder path (default /)") String path) {
        return Response.text(serverManager.listRepositoryFiles(repo, path));
    }

    @McpTool(path = "/server/repository/file",
        description = "Get metadata for a specific file in a repository.",
        category = "server")
    public Response getFileInfo(
            @Param(value = "repo", description = "Repository name") String repo,
            @Param(value = "path", description = "File path within the repository") String path) {
        return Response.text(serverManager.getFileInfo(repo, path));
    }

    @McpTool(path = "/server/repository/create", method = "POST",
        description = "Create a new repository on the connected Ghidra Server.",
        category = "server")
    public Response createRepository(
            @Param(value = "name", source = ParamSource.BODY, description = "Repository name") String name) {
        return Response.text(serverManager.createRepository(name));
    }

    // ========================================================================
    // Version control (real implementations only)
    // ========================================================================

    @McpTool(path = "/server/version_control/checkout", method = "POST",
        description = "Check out a file from a repository (exclusive lock via RepositoryAdapter).",
        category = "server")
    public Response checkoutFile(
            @Param(value = "repo", source = ParamSource.BODY, description = "Repository name") String repo,
            @Param(value = "path", source = ParamSource.BODY, description = "File path within the repository") String path) {
        return Response.text(serverManager.checkoutFile(repo, path));
    }

    @McpTool(path = "/server/version_history",
        description = "Get the version history of a file in a repository.",
        category = "server")
    public Response getVersionHistory(
            @Param(value = "repo", description = "Repository name") String repo,
            @Param(value = "path", description = "File path within the repository") String path) {
        return Response.text(serverManager.getVersionHistory(repo, path));
    }

    @McpTool(path = "/server/checkouts",
        description = "Get current checkouts (active locks) for a file in a repository.",
        category = "server")
    public Response getCheckouts(
            @Param(value = "repo", description = "Repository name") String repo,
            @Param(value = "path", description = "File path within the repository") String path) {
        return Response.text(serverManager.getCheckouts(repo, path));
    }

    // ========================================================================
    // Admin
    // ========================================================================

    @McpTool(path = "/server/admin/users",
        description = "List all users registered on the Ghidra Server (requires admin access).",
        category = "server")
    public Response listServerUsers() {
        return Response.text(serverManager.listServerUsers());
    }

    @McpTool(path = "/server/admin/set_permissions", method = "POST",
        description = "Set a user's access level for a repository (requires admin). "
            + "Levels: 0=no_access, 1=read_only, 2=read_write, 3=admin.",
        category = "server")
    public Response setUserPermissions(
            @Param(value = "repo", source = ParamSource.BODY, description = "Repository name") String repo,
            @Param(value = "user", source = ParamSource.BODY, description = "User name") String user,
            @Param(value = "accessLevel", source = ParamSource.BODY, defaultValue = "1",
                description = "Access level: 0=no_access, 1=read_only, 2=read_write, 3=admin") int accessLevel) {
        return Response.text(serverManager.setUserPermissions(repo, user, accessLevel));
    }

    @McpTool(path = "/server/admin/terminate_checkout", method = "POST",
        description = "Forcibly terminate another user's checkout on a file.",
        category = "server")
    public Response terminateCheckout(
            @Param(value = "repo", source = ParamSource.BODY, description = "Repository name") String repo,
            @Param(value = "path", source = ParamSource.BODY, description = "File path") String path,
            @Param(value = "checkoutId", source = ParamSource.BODY, description = "Checkout ID to terminate") long checkoutId) {
        return Response.text(serverManager.terminateCheckout(repo, path, checkoutId));
    }

    @McpTool(path = "/server/admin/terminate_all_checkouts", method = "POST",
        description = "Forcibly terminate every checkout under a repository folder (recursive).",
        category = "server")
    public Response terminateAllCheckouts(
            @Param(value = "repo", source = ParamSource.BODY, description = "Repository name") String repo,
            @Param(value = "path", source = ParamSource.BODY, defaultValue = "/",
                description = "Folder path (default / for entire repo)") String path) {
        return Response.text(serverManager.terminateAllCheckouts(repo, path));
    }
}
