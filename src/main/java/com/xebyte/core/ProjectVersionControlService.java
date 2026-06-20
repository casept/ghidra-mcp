package com.xebyte.core;

import ghidra.framework.client.RepositoryAdapter;
import ghidra.framework.model.DomainFile;
import ghidra.framework.model.DomainFolder;
import ghidra.framework.model.Project;
import ghidra.framework.model.ProjectData;
import ghidra.framework.plugintool.PluginTool;
import ghidra.framework.store.ItemCheckoutStatus;
import ghidra.util.task.ConsoleTaskMonitor;

import java.io.IOException;
import java.util.Date;

/**
 * MCP tools for GUI-mode project version control. Operates on the open
 * Ghidra project's {@link DomainFile} objects — real checkin, checkout,
 * undo, and version history via the project's server binding.
 *
 * <p>GUI-only: the headless equivalent is {@link SharedRepositoryService}
 * which uses a standalone {@link com.xebyte.headless.GhidraServerManager}
 * connection. Both register the same {@code /server/*} paths — only one
 * is wired into the {@link AnnotationScanner} per mode.
 */
@McpToolGroup(value = "server", description = "Shared project version control — browse, checkout, checkin, history, admin")
public class ProjectVersionControlService {

    private final PluginTool tool;

    public ProjectVersionControlService(PluginTool tool) {
        this.tool = tool;
    }

    // ========================================================================
    // Connection (project-based — no separate connect/disconnect needed)
    // ========================================================================

    @McpTool(path = "/server/connect", method = "POST",
        description = "GUI mode: reports the open project's server binding. "
            + "No separate connection needed — the project IS the connection.",
        category = "server")
    public Response serverConnect() {
        Project project = tool.getProject();
        if (project == null) {
            return Response.text("{\"error\": \"No project open in Ghidra\"}");
        }
        ProjectData data = project.getProjectData();
        boolean isShared = !data.getProjectLocator().isTransient() && getProjectRepository() != null;
        return Response.text("{\"status\": \"connected\", \"project\": \"" + esc(project.getName()) + "\", " +
            "\"shared\": " + isShared + ", " +
            "\"message\": \"GUI plugin uses the open Ghidra project directly. No separate connection needed.\"}");
    }

    @McpTool(path = "/server/disconnect", method = "POST",
        description = "GUI mode: no-op (project-based connection).",
        category = "server")
    public Response serverDisconnect() {
        return Response.text("{\"status\": \"ok\", \"message\": \"GUI plugin uses the open project. No disconnect needed.\"}");
    }

    @McpTool(path = "/server/status",
        description = "Project status: connection, shared flag, server info, file count.",
        category = "server")
    public Response serverStatus() {
        return Response.text(getProjectStatusJson());
    }

    // ========================================================================
    // Repository browsing
    // ========================================================================

    @McpTool(path = "/server/repositories",
        description = "List all repositories on the connected Ghidra Server.",
        category = "server")
    public Response listRepositories() {
        Project project = tool.getProject();
        if (project == null) {
            return Response.text("{\"error\": \"No project open\"}");
        }
        RepositoryAdapter repo = getProjectRepository();
        if (repo == null) {
            return Response.text("{\"repositories\": [\"" + esc(project.getName()) + "\"], \"count\": 1, " +
                "\"shared\": false, \"message\": \"Project is local-only (not shared). Shows current project only.\"}");
        }
        try {
            ghidra.framework.client.RepositoryServerAdapter serverAdapter = repo.getServer();
            String[] names = serverAdapter.getRepositoryNames();
            StringBuilder sb = new StringBuilder();
            sb.append("{\"repositories\": [");
            for (int i = 0; i < names.length; i++) {
                if (i > 0) sb.append(", ");
                sb.append("\"").append(esc(names[i])).append("\"");
            }
            sb.append("], \"count\": ").append(names.length);
            sb.append(", \"current_project\": \"").append(esc(project.getName())).append("\"");
            sb.append(", \"server_info\": \"").append(esc(repo.getServerInfo().toString())).append("\"}");
            return Response.text(sb.toString());
        } catch (Exception e) {
            return Response.text("{\"error\": \"Failed to list repositories: " + esc(e.getMessage()) + "\"}");
        }
    }

    @McpTool(path = "/server/repository/files",
        description = "List files and folders in a project path.",
        category = "server")
    public Response listRepositoryFiles(
            @Param(value = "path", defaultValue = "/", description = "Folder path (default /)") String path) {
        return Response.text(listProjectFilesJson(path));
    }

    @McpTool(path = "/server/repository/file",
        description = "Get metadata for a specific file (version, checkout status, etc.).",
        category = "server")
    public Response getFileInfo(
            @Param(value = "path", description = "File path within the project") String path) {
        if (path == null) {
            return Response.text("{\"error\": \"'path' parameter required\"}");
        }
        return Response.text(getProjectFileInfoJson(path));
    }

    @McpTool(path = "/server/repository/create", method = "POST",
        description = "Not available in GUI mode — use Ghidra's Project Manager or headless mode.",
        category = "server")
    public Response createRepository(
            @Param(value = "name", source = ParamSource.BODY, description = "Repository name") String name) {
        return Response.text("{\"error\": \"Repository creation not available in GUI mode. " +
            "Use Ghidra's Project Manager or headless mode.\"}");
    }

    // ========================================================================
    // Version control
    // ========================================================================

    @McpTool(path = "/server/version_control/checkout", method = "POST",
        description = "Check out a file from the shared project (DomainFile.checkout).",
        category = "server")
    public Response checkoutFile(
            @Param(value = "path", source = ParamSource.BODY, description = "File path within the project") String path,
            @Param(value = "exclusive", source = ParamSource.BODY, defaultValue = "true",
                description = "Exclusive checkout (default true)") boolean exclusive) {
        return Response.text(checkoutProjectFile(path, exclusive));
    }

    @McpTool(path = "/server/version_control/checkin", method = "POST",
        description = "Check in a file to the shared project (DomainFile.checkin). "
            + "Persists all local changes (renames, comments, types) to the server.",
        category = "server")
    public Response checkinFile(
            @Param(value = "path", source = ParamSource.BODY, description = "File path within the project") String path,
            @Param(value = "comment", source = ParamSource.BODY, defaultValue = "Checked in via GhidraMCP",
                description = "Checkin comment") String comment,
            @Param(value = "keepCheckedOut", source = ParamSource.BODY, defaultValue = "false",
                description = "Keep the file checked out after checkin") boolean keepCheckedOut) {
        return Response.text(checkinProjectFile(path, comment, keepCheckedOut));
    }

    @McpTool(path = "/server/version_control/undo_checkout", method = "POST",
        description = "Undo checkout, optionally keeping a local copy of changes.",
        category = "server")
    public Response undoCheckout(
            @Param(value = "path", source = ParamSource.BODY, description = "File path within the project") String path,
            @Param(value = "keep", source = ParamSource.BODY, defaultValue = "false",
                description = "Keep a local copy of the checked-out version") boolean keep) {
        return Response.text(undoCheckoutProjectFile(path, keep));
    }

    @McpTool(path = "/server/version_control/add", method = "POST",
        description = "Add a local file to version control on the shared server.",
        category = "server")
    public Response addToVersionControl(
            @Param(value = "path", source = ParamSource.BODY, description = "File path within the project") String path,
            @Param(value = "comment", source = ParamSource.BODY, defaultValue = "Added via GhidraMCP",
                description = "Initial version comment") String comment) {
        return Response.text(addToVersionControlImpl(path, comment));
    }

    // ========================================================================
    // Version history & checkouts
    // ========================================================================

    @McpTool(path = "/server/version_history",
        description = "Get version history for a file (all versions with user, comment, date).",
        category = "server")
    public Response getVersionHistory(
            @Param(value = "path", description = "File path within the project") String path) {
        return Response.text(getProjectFileVersionHistory(path));
    }

    @McpTool(path = "/server/checkouts",
        description = "List all checked-out files in a folder, including server-side checkouts.",
        category = "server")
    public Response getCheckouts(
            @Param(value = "path", defaultValue = "/", description = "Folder path (default /)") String path) {
        return Response.text(listProjectCheckouts(path));
    }

    // ========================================================================
    // Admin
    // ========================================================================

    @McpTool(path = "/server/admin/terminate_checkout", method = "POST",
        description = "Terminate a file's checkout: tries local undo first, then server-side termination.",
        category = "server")
    public Response terminateCheckout(
            @Param(value = "path", source = ParamSource.BODY, description = "File path") String path) {
        return Response.text(terminateFileCheckout(path));
    }

    @McpTool(path = "/server/admin/terminate_all_checkouts", method = "POST",
        description = "Terminate all checkouts under a folder recursively.",
        category = "server")
    public Response terminateAllCheckouts(
            @Param(value = "path", source = ParamSource.BODY, defaultValue = "/",
                description = "Folder path (default / for entire project)") String path) {
        return Response.text(terminateAllCheckoutsImpl(path));
    }

    @McpTool(path = "/server/admin/users",
        description = "Not available in GUI mode — requires headless with direct server connection.",
        category = "server")
    public Response listServerUsers() {
        return Response.text("{\"error\": \"User listing requires headless mode with direct server connection.\"}");
    }

    @McpTool(path = "/server/admin/set_permissions", method = "POST",
        description = "Not available in GUI mode — requires headless with direct server connection.",
        category = "server")
    public Response setUserPermissions(
            @Param(value = "repo", source = ParamSource.BODY, description = "Repository name") String repo,
            @Param(value = "user", source = ParamSource.BODY, description = "User name") String user,
            @Param(value = "accessLevel", source = ParamSource.BODY, defaultValue = "1",
                description = "Access level") int accessLevel) {
        return Response.text("{\"error\": \"Permission management requires headless mode with direct server connection.\"}");
    }

    // ========================================================================
    // Internal helpers (extracted from GhidraMCPPlugin)
    // ========================================================================

    private RepositoryAdapter getProjectRepository() {
        try {
            Project project = tool.getProject();
            if (project == null) return null;
            ProjectData data = project.getProjectData();
            java.lang.reflect.Method m = data.getClass().getMethod("getRepository");
            return (RepositoryAdapter) m.invoke(data);
        } catch (Exception e) {
            return null;
        }
    }

    private String getProjectStatusJson() {
        Project project = tool.getProject();
        if (project == null) {
            return "{\"connected\": false, \"error\": \"No project open\"}";
        }
        ProjectData data = project.getProjectData();
        RepositoryAdapter repo = getProjectRepository();
        StringBuilder sb = new StringBuilder();
        sb.append("{\"connected\": true");
        sb.append(", \"project\": \"").append(esc(project.getName())).append("\"");
        sb.append(", \"shared\": ").append(repo != null);
        if (repo != null) {
            try {
                sb.append(", \"server_connected\": ").append(repo.isConnected());
                sb.append(", \"server_info\": \"").append(esc(repo.getServerInfo().toString())).append("\"");
            } catch (Exception e) {
                sb.append(", \"server_connected\": false");
            }
        }
        sb.append(", \"file_count\": ").append(data.getFileCount());
        sb.append("}");
        return sb.toString();
    }

    private String listProjectFilesJson(String folderPath) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        ProjectData data = project.getProjectData();
        DomainFolder folder;
        if (folderPath == null || folderPath.isEmpty() || folderPath.equals("/")) {
            folder = data.getRootFolder();
        } else {
            folder = data.getFolder(folderPath);
        }
        if (folder == null) return "{\"error\": \"Folder not found: " + esc(folderPath) + "\"}";

        StringBuilder sb = new StringBuilder();
        sb.append("{\"folder\": \"").append(esc(folder.getPathname())).append("\", \"files\": [");
        DomainFile[] files = folder.getFiles();
        for (int i = 0; i < files.length; i++) {
            if (i > 0) sb.append(", ");
            appendFileJson(sb, files[i]);
        }
        sb.append("], \"folders\": [");
        DomainFolder[] folders = folder.getFolders();
        for (int i = 0; i < folders.length; i++) {
            if (i > 0) sb.append(", ");
            sb.append("\"").append(esc(folders[i].getName())).append("\"");
        }
        sb.append("], \"file_count\": ").append(files.length);
        sb.append(", \"folder_count\": ").append(folders.length).append("}");
        return sb.toString();
    }

    private void appendFileJson(StringBuilder sb, DomainFile f) {
        sb.append("{\"name\": \"").append(esc(f.getName())).append("\"");
        sb.append(", \"path\": \"").append(esc(f.getPathname())).append("\"");
        sb.append(", \"version\": ").append(f.getVersion());
        sb.append(", \"latest_version\": ").append(f.getLatestVersion());
        sb.append(", \"is_versioned\": ").append(f.isVersioned());
        sb.append(", \"is_checked_out\": ").append(f.isCheckedOut());
        sb.append(", \"is_checked_out_exclusive\": ").append(f.isCheckedOutExclusive());
        sb.append(", \"is_read_only\": ").append(f.isReadOnly());
        if (f.isCheckedOut()) {
            try {
                ItemCheckoutStatus status = f.getCheckoutStatus();
                if (status != null) {
                    sb.append(", \"checkout_user\": \"").append(esc(status.getUser())).append("\"");
                    sb.append(", \"checkout_id\": ").append(status.getCheckoutId());
                    sb.append(", \"checkout_version\": ").append(status.getCheckoutVersion());
                }
            } catch (IOException e) {
                sb.append(", \"checkout_error\": \"").append(esc(e.getMessage())).append("\"");
            }
        }
        sb.append("}");
    }

    private String getProjectFileInfoJson(String filePath) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        DomainFile file = project.getProjectData().getFile(filePath);
        if (file == null) return "{\"error\": \"File not found: " + esc(filePath) + "\"}";
        StringBuilder sb = new StringBuilder();
        appendFileJson(sb, file);
        return sb.toString();
    }

    private String checkoutProjectFile(String filePath, boolean exclusive) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        if (filePath == null) return "{\"error\": \"'path' parameter required\"}";
        DomainFile file = project.getProjectData().getFile(filePath);
        if (file == null) return "{\"error\": \"File not found: " + esc(filePath) + "\"}";
        try {
            boolean success = file.checkout(exclusive, new ConsoleTaskMonitor());
            return "{\"status\": \"" + (success ? "checked_out" : "checkout_failed") + "\", " +
                "\"path\": \"" + esc(filePath) + "\", \"exclusive\": " + exclusive + "}";
        } catch (Exception e) {
            return "{\"error\": \"Checkout failed: " + esc(e.getMessage()) + "\"}";
        }
    }

    private String checkinProjectFile(String filePath, String comment, boolean keepCheckedOut) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        if (filePath == null) return "{\"error\": \"'path' parameter required\"}";
        DomainFile file = project.getProjectData().getFile(filePath);
        if (file == null) return "{\"error\": \"File not found: " + esc(filePath) + "\"}";
        if (!file.isCheckedOut()) return "{\"error\": \"File is not checked out: " + esc(filePath) + "\"}";
        try {
            file.checkin(new ghidra.framework.data.CheckinHandler() {
                public boolean keepCheckedOut() { return keepCheckedOut; }
                public String getComment() { return comment; }
                public boolean createKeepFile() { return false; }
            }, new ConsoleTaskMonitor());
            return "{\"status\": \"checked_in\", \"path\": \"" + esc(filePath) + "\", " +
                "\"comment\": \"" + esc(comment) + "\", \"keep_checked_out\": " + keepCheckedOut + "}";
        } catch (Exception e) {
            return "{\"error\": \"Checkin failed: " + esc(e.getMessage()) + "\"}";
        }
    }

    private String undoCheckoutProjectFile(String filePath, boolean keep) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        if (filePath == null) return "{\"error\": \"'path' parameter required\"}";
        DomainFile file = project.getProjectData().getFile(filePath);
        if (file == null) return "{\"error\": \"File not found: " + esc(filePath) + "\"}";
        if (!file.isCheckedOut()) return "{\"error\": \"File is not checked out: " + esc(filePath) + "\"}";
        try {
            file.undoCheckout(keep);
            return "{\"status\": \"checkout_undone\", \"path\": \"" + esc(filePath) + "\", \"kept_copy\": " + keep + "}";
        } catch (Exception e) {
            return "{\"error\": \"Undo checkout failed: " + esc(e.getMessage()) + "\"}";
        }
    }

    private String addToVersionControlImpl(String filePath, String comment) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        if (filePath == null) return "{\"error\": \"'path' parameter required\"}";
        DomainFile file = project.getProjectData().getFile(filePath);
        if (file == null) return "{\"error\": \"File not found: " + esc(filePath) + "\"}";
        if (file.isVersioned()) return "{\"error\": \"File already under version control: " + esc(filePath) + "\"}";
        try {
            file.addToVersionControl(comment, false, new ConsoleTaskMonitor());
            return "{\"status\": \"added\", \"path\": \"" + esc(filePath) + "\", \"comment\": \"" + esc(comment) + "\"}";
        } catch (Exception e) {
            return "{\"error\": \"Add to version control failed: " + esc(e.getMessage()) + "\"}";
        }
    }

    private String getProjectFileVersionHistory(String filePath) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        if (filePath == null) return "{\"error\": \"'path' parameter required\"}";
        DomainFile file = project.getProjectData().getFile(filePath);
        if (file == null) return "{\"error\": \"File not found: " + esc(filePath) + "\"}";
        try {
            ghidra.framework.store.Version[] versions = file.getVersionHistory();
            StringBuilder sb = new StringBuilder();
            sb.append("{\"path\": \"").append(esc(filePath)).append("\", \"versions\": [");
            for (int i = 0; i < versions.length; i++) {
                if (i > 0) sb.append(", ");
                sb.append("{\"version\": ").append(versions[i].getVersion());
                sb.append(", \"user\": \"").append(esc(versions[i].getUser())).append("\"");
                sb.append(", \"comment\": \"").append(esc(versions[i].getComment() != null ? versions[i].getComment() : "")).append("\"");
                sb.append(", \"date\": \"").append(new Date(versions[i].getCreateTime())).append("\"");
                sb.append("}");
            }
            sb.append("], \"count\": ").append(versions.length).append("}");
            return sb.toString();
        } catch (Exception e) {
            return "{\"error\": \"Failed to get version history: " + esc(e.getMessage()) + "\"}";
        }
    }

    private String listProjectCheckouts(String folderPath) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        ProjectData data = project.getProjectData();
        DomainFolder folder;
        if (folderPath == null || folderPath.isEmpty() || folderPath.equals("/")) {
            folder = data.getRootFolder();
        } else {
            folder = data.getFolder(folderPath);
        }
        if (folder == null) return "{\"error\": \"Folder not found: " + esc(folderPath) + "\"}";

        RepositoryAdapter repo = getProjectRepository();
        StringBuilder sb = new StringBuilder();
        sb.append("{\"checkouts\": [");
        int count = collectCheckouts(sb, folder, 0, repo);
        sb.append("], \"count\": ").append(count).append("}");
        return sb.toString();
    }

    private int collectCheckouts(StringBuilder sb, DomainFolder folder, int count, RepositoryAdapter repo) {
        for (DomainFile f : folder.getFiles()) {
            boolean localCheckout = f.isCheckedOut();
            ItemCheckoutStatus[] serverCheckouts = null;
            if (repo != null && f.isVersioned()) {
                try {
                    String path = f.getPathname();
                    int lastSlash = path.lastIndexOf('/');
                    String parentPath = lastSlash > 0 ? path.substring(0, lastSlash) : "/";
                    String fileName = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
                    serverCheckouts = repo.getCheckouts(parentPath, fileName);
                } catch (Exception e) { /* skip */ }
            }
            boolean serverCheckout = serverCheckouts != null && serverCheckouts.length > 0;
            if (localCheckout || serverCheckout) {
                if (count > 0) sb.append(", ");
                appendFileJson(sb, f);
                if (serverCheckout) {
                    sb.setLength(sb.length() - 1);
                    sb.append(", \"server_checkouts\": [");
                    for (int i = 0; i < serverCheckouts.length; i++) {
                        if (i > 0) sb.append(", ");
                        sb.append("{\"checkout_id\": ").append(serverCheckouts[i].getCheckoutId());
                        sb.append(", \"user\": \"").append(esc(serverCheckouts[i].getUser())).append("\"");
                        sb.append(", \"checkout_version\": ").append(serverCheckouts[i].getCheckoutVersion());
                        sb.append("}");
                    }
                    sb.append("]}");
                }
                count++;
            }
        }
        for (DomainFolder sub : folder.getFolders()) {
            count = collectCheckouts(sb, sub, count, repo);
        }
        return count;
    }

    private String terminateFileCheckout(String filePath) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        if (filePath == null) return "{\"error\": \"'path' parameter required\"}";
        DomainFile file = project.getProjectData().getFile(filePath);
        if (file == null) return "{\"error\": \"File not found: " + esc(filePath) + "\"}";
        if (file.isCheckedOut()) {
            try {
                file.undoCheckout(false, true);
                return "{\"status\": \"terminated\", \"path\": \"" + esc(filePath) + "\", \"method\": \"undo_checkout_force\"}";
            } catch (Exception e) { /* fall through */ }
        }
        RepositoryAdapter repo = getProjectRepository();
        if (repo == null) {
            return "{\"error\": \"Cannot terminate checkout: project has no repository connection\"}";
        }
        try {
            int lastSlash = filePath.lastIndexOf('/');
            String parentPath = lastSlash > 0 ? filePath.substring(0, lastSlash) : "/";
            String fileName = lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath;
            ItemCheckoutStatus[] checkouts = repo.getCheckouts(parentPath, fileName);
            if (checkouts == null || checkouts.length == 0) {
                return "{\"error\": \"No active checkouts found for: " + esc(filePath) + "\"}";
            }
            int terminated = 0;
            for (ItemCheckoutStatus cs : checkouts) {
                try {
                    repo.terminateCheckout(parentPath, fileName, cs.getCheckoutId(), false);
                    terminated++;
                } catch (Exception e) { /* continue */ }
            }
            return "{\"status\": \"terminated\", \"path\": \"" + esc(filePath) + "\", " +
                "\"terminated_count\": " + terminated + ", \"total_checkouts\": " + checkouts.length + "}";
        } catch (Exception e) {
            return "{\"error\": \"Terminate checkout failed: " + esc(e.getMessage()) + "\"}";
        }
    }

    private String terminateAllCheckoutsImpl(String folderPath) {
        Project project = tool.getProject();
        if (project == null) return "{\"error\": \"No project open\"}";
        ProjectData data = project.getProjectData();
        DomainFolder folder;
        if (folderPath == null || folderPath.isEmpty() || folderPath.equals("/")) {
            folder = data.getRootFolder();
        } else {
            folder = data.getFolder(folderPath);
        }
        if (folder == null) return "{\"error\": \"Folder not found: " + esc(folderPath) + "\"}";
        RepositoryAdapter repo = getProjectRepository();
        if (repo == null) {
            return "{\"error\": \"Cannot terminate checkouts: project has no repository connection\"}";
        }
        StringBuilder details = new StringBuilder();
        details.append("[");
        int[] counts = {0, 0};
        terminateCheckoutsRecursive(folder, repo, details, counts);
        details.append("]");
        return "{\"status\": \"terminated\", \"folder\": \"" + esc(folderPath != null ? folderPath : "/") + "\", " +
            "\"files_with_checkouts\": " + counts[0] + ", " +
            "\"checkouts_terminated\": " + counts[1] + ", " +
            "\"details\": " + details.toString() + "}";
    }

    private void terminateCheckoutsRecursive(DomainFolder folder, RepositoryAdapter repo, StringBuilder details, int[] counts) {
        for (DomainFile f : folder.getFiles()) {
            if (!f.isVersioned()) continue;
            try {
                String path = f.getPathname();
                int lastSlash = path.lastIndexOf('/');
                String parentPath = lastSlash > 0 ? path.substring(0, lastSlash) : "/";
                String fileName = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
                ItemCheckoutStatus[] checkouts = repo.getCheckouts(parentPath, fileName);
                if (checkouts != null && checkouts.length > 0) {
                    int terminated = 0;
                    for (ItemCheckoutStatus cs : checkouts) {
                        try {
                            repo.terminateCheckout(parentPath, fileName, cs.getCheckoutId(), false);
                            terminated++;
                        } catch (Exception e) { /* continue */ }
                    }
                    if (counts[0] > 0) details.append(", ");
                    details.append("{\"path\": \"").append(esc(path)).append("\"");
                    details.append(", \"terminated\": ").append(terminated);
                    details.append(", \"total\": ").append(checkouts.length).append("}");
                    counts[0]++;
                    counts[1] += terminated;
                }
            } catch (Exception e) { /* skip file */ }
        }
        for (DomainFolder sub : folder.getFolders()) {
            terminateCheckoutsRecursive(sub, repo, details, counts);
        }
    }

    private static String esc(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }
}
