package com.xebyte.offline;

import com.xebyte.core.Response;
import com.xebyte.core.SharedRepositoryService;
import com.xebyte.headless.GhidraServerManager;
import junit.framework.TestCase;

/**
 * Offline tests for SharedRepositoryService — exercises all error paths
 * that occur when the Ghidra Server is unreachable, disconnected, or
 * credentials are missing. No live server needed.
 */
public class SharedRepositoryServiceTest extends TestCase {

    private SharedRepositoryService service;
    private GhidraServerManager serverManager;

    @Override
    protected void setUp() {
        serverManager = new GhidraServerManager("localhost", 13100, null, null);
        service = new SharedRepositoryService(serverManager);
    }

    // ========================================================================
    // Connection — no credentials configured
    // ========================================================================

    public void testConnectWithoutCredentialsReturnsError() {
        Response r = service.serverConnect();
        String json = r.toJson();
        assertTrue("Expected credentials error, got: " + json,
            json.contains("Credentials not configured"));
    }

    public void testStatusWhenDisconnected() {
        Response r = service.serverStatus();
        String json = r.toJson();
        assertTrue("Expected connected:false, got: " + json,
            json.contains("\"connected\": false"));
        assertTrue("Expected credentials_configured:false, got: " + json,
            json.contains("\"credentials_configured\": false"));
    }

    public void testDisconnectWhenNotConnected() {
        Response r = service.serverDisconnect();
        String json = r.toJson();
        assertTrue("Expected not_connected, got: " + json,
            json.contains("not_connected"));
    }

    // ========================================================================
    // Repository browsing — not connected
    // ========================================================================

    public void testListRepositoriesWhenDisconnected() {
        Response r = service.listRepositories();
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testListRepositoryFilesWhenDisconnected() {
        Response r = service.listRepositoryFiles("test-repo", "/");
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testGetFileInfoWhenDisconnected() {
        Response r = service.getFileInfo("test-repo", "/some/file");
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testCreateRepositoryWhenDisconnected() {
        Response r = service.createRepository("new-repo");
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    // ========================================================================
    // Version control — not connected
    // ========================================================================

    public void testCheckoutFileWhenDisconnected() {
        Response r = service.checkoutFile("test-repo", "/some/file");
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testGetVersionHistoryWhenDisconnected() {
        Response r = service.getVersionHistory("test-repo", "/some/file");
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testGetCheckoutsWhenDisconnected() {
        Response r = service.getCheckouts("test-repo", "/some/file");
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    // ========================================================================
    // Admin — not connected
    // ========================================================================

    public void testListServerUsersWhenDisconnected() {
        Response r = service.listServerUsers();
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testSetUserPermissionsWhenDisconnected() {
        Response r = service.setUserPermissions("test-repo", "testuser", 2);
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testTerminateCheckoutWhenDisconnected() {
        Response r = service.terminateCheckout("test-repo", "/some/file", 42);
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    public void testTerminateAllCheckoutsWhenDisconnected() {
        Response r = service.terminateAllCheckouts("test-repo", "/");
        String json = r.toJson();
        assertTrue("Expected 'Not connected' error, got: " + json,
            json.contains("Not connected"));
    }

    // ========================================================================
    // Input validation
    // ========================================================================

    public void testListRepositoryFilesDefaultsPath() {
        Response r = service.listRepositoryFiles("test-repo", null);
        String json = r.toJson();
        assertTrue("Expected 'Not connected' (not NPE), got: " + json,
            json.contains("Not connected") || json.contains("error"));
    }

    public void testCreateRepositoryWithEmptyName() {
        Response r = service.createRepository("");
        String json = r.toJson();
        assertTrue("Expected error for empty name, got: " + json,
            json.contains("error"));
    }

    public void testTerminateAllCheckoutsDefaultsPath() {
        Response r = service.terminateAllCheckouts("test-repo", null);
        String json = r.toJson();
        assertTrue("Expected 'Not connected' (not NPE), got: " + json,
            json.contains("Not connected") || json.contains("error"));
    }

    // ========================================================================
    // All 14 tools return valid JSON (not exceptions)
    // ========================================================================

    public void testAllToolsReturnJsonNotExceptions() {
        Response[] responses = {
            service.serverConnect(),
            service.serverDisconnect(),
            service.serverStatus(),
            service.listRepositories(),
            service.listRepositoryFiles("repo", "/"),
            service.getFileInfo("repo", "/file"),
            service.createRepository("repo"),
            service.checkoutFile("repo", "/file"),
            service.getVersionHistory("repo", "/file"),
            service.getCheckouts("repo", "/file"),
            service.listServerUsers(),
            service.setUserPermissions("repo", "user", 1),
            service.terminateCheckout("repo", "/file", 1),
            service.terminateAllCheckouts("repo", "/"),
        };
        for (int i = 0; i < responses.length; i++) {
            assertNotNull("Tool " + i + " returned null", responses[i]);
            String json = responses[i].toJson();
            assertNotNull("Tool " + i + " toJson() returned null", json);
            assertTrue("Tool " + i + " returned empty string", json.length() > 0);
            assertTrue("Tool " + i + " must be valid JSON (starts with {), got: " + json.substring(0, Math.min(50, json.length())),
                json.startsWith("{"));
        }
    }
}
