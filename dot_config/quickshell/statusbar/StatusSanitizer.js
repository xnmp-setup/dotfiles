.pragma library

const MAX_WORKSPACES = 64;
const MAX_CLIENTS_PER_WORKSPACE = 128;
const MAX_ACTIVITIES_PER_CLIENT = 32;

function safeString(value, fallback, limit) {
    if (typeof value !== "string")
        return fallback;
    return value.slice(0, limit);
}

function boundedInteger(value, fallback, minimum, maximum) {
    if (typeof value !== "number" || !Number.isFinite(value))
        return fallback;
    return Math.max(minimum, Math.min(maximum, Math.floor(value)));
}

function mergeObject(base, update) {
    const merged = {};
    for (const key in base)
        merged[key] = base[key];
    if (update !== null && typeof update === "object") {
        for (const key in update)
            merged[key] = update[key];
    }
    return merged;
}

function normalizedPercent(value, fallback) {
    if (value === null)
        return null;
    return boundedInteger(value, fallback, 0, 100);
}

function normalizedTimestamp(value, fallback) {
    if (value === null)
        return null;
    return boundedInteger(value, fallback, 1, 4102444800);
}

function normalizedWindowMinutes(value, fallback) {
    if (value === null)
        return null;
    return boundedInteger(value, fallback, 1, 525600);
}

function normalizeUsageProvider(base, raw) {
    const provider = mergeObject({}, base);
    if (raw === null || typeof raw !== "object" || Array.isArray(raw))
        return provider;
    for (const key of ["percent", "secondaryPercent"]) {
        if (key in raw)
            provider[key] = normalizedPercent(raw[key], provider[key]);
    }
    for (const key of ["resetsAt", "secondaryResetsAt"]) {
        if (key in raw)
            provider[key] = normalizedTimestamp(raw[key], provider[key]);
    }
    for (const key of ["windowMinutes", "secondaryWindowMinutes"]) {
        if (key in raw)
            provider[key] = normalizedWindowMinutes(raw[key], provider[key]);
    }
    return provider;
}

function normalizeUsage(base, raw) {
    const usage = mergeObject({}, base);
    if (raw === null || typeof raw !== "object" || Array.isArray(raw))
        return usage;
    for (const provider of ["claude", "codex"]) {
        if (provider in raw)
            usage[provider] = normalizeUsageProvider(usage[provider], raw[provider]);
    }
    return usage;
}

function normalizedHotTemperature(value, fallback) {
    if (value === null)
        return null;
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 200)
        return fallback;
    const temperature = Math.floor(value);
    return temperature >= 75 ? temperature : null;
}

function normalizeMetrics(base, raw) {
    const metrics = mergeObject({}, base);
    if (raw === null || typeof raw !== "object" || Array.isArray(raw))
        return metrics;

    for (const key of ["cpu", "ram", "io", "gpu", "battery", "wifi"]) {
        if (key in raw)
            metrics[key] = normalizedPercent(raw[key], metrics[key]);
    }
    if ("cpuTemp" in raw)
        metrics.cpuTemp = normalizedHotTemperature(raw.cpuTemp, metrics.cpuTemp);
    if ("gpuTemp" in raw)
        metrics.gpuTemp = normalizedHotTemperature(raw.gpuTemp, metrics.gpuTemp);
    if (typeof raw.laptop === "boolean")
        metrics.laptop = raw.laptop;
    if (typeof raw.wifiConnected === "boolean")
        metrics.wifiConnected = raw.wifiConnected;
    for (const key of ["ioTooltip", "batteryTooltip", "wifiTooltip"]) {
        if (key in raw)
            metrics[key] = safeString(raw[key], metrics[key], 512);
    }
    return metrics;
}

function normalizeClient(raw) {
    const client = raw !== null && typeof raw === "object" ? raw : {};
    const rawActivities = Array.isArray(client.activities) ? client.activities : [];
    const activities = [];
    for (let index = 0;
         index < rawActivities.length && index < MAX_ACTIVITIES_PER_CLIENT;
         index += 1) {
        const rawActivity = rawActivities[index];
        if (rawActivity === null || typeof rawActivity !== "object")
            continue;
        const rawKind = safeString(rawActivity.kind, "process", 16);
        const kind = ["claude", "codex", "process"].includes(rawKind)
            ? rawKind
            : "process";
        const rawState = safeString(rawActivity.state, "idle", 16);
        const state = kind === "process"
            ? ""
            : ["working", "idle", "attention"].includes(rawState)
                ? rawState
                : "idle";
        activities.push({
            kind: kind,
            state: state,
            title: safeString(rawActivity.title, kind === "process" ? "Shell" : "", 160)
        });
    }
    return {
        address: safeString(client.address, "", 128),
        class: safeString(client.class, "application", 256),
        icon: safeString(client.icon, "application-x-executable", 1024),
        label: safeString(client.label, "Application", 64),
        title: safeString(client.title, "", 256),
        terminal: client.terminal === true,
        tabs: boundedInteger(client.tabs, 1, 1, 9999),
        claude: boundedInteger(client.claude, 0, 0, 9999),
        codex: boundedInteger(client.codex, 0, 0, 9999),
        activities: activities
    };
}

function normalizeWorkspace(raw) {
    if (raw === null || typeof raw !== "object")
        return null;
    if (typeof raw.id !== "number" || !Number.isFinite(raw.id) || raw.id < 1)
        return null;
    const id = boundedInteger(raw.id, 0, 1, 999999);
    const rawClients = Array.isArray(raw.clients) ? raw.clients : [];
    const clients = [];
    for (let index = 0;
         index < rawClients.length && index < MAX_CLIENTS_PER_WORKSPACE;
         index += 1) {
        clients.push(normalizeClient(rawClients[index]));
    }
    if (clients.length === 0)
        return null;
    return {
        id: id,
        name: safeString(raw.name, String(id), 32),
        monitor: safeString(raw.monitor, "", 128),
        active: raw.active === true,
        clients: clients,
        claude: boundedInteger(raw.claude, 0, 0, 9999),
        codex: boundedInteger(raw.codex, 0, 0, 9999)
    };
}

function normalizeWorkspaces(raw) {
    if (!Array.isArray(raw))
        return [];
    const workspaces = [];
    for (let index = 0;
         index < raw.length && workspaces.length < MAX_WORKSPACES;
         index += 1) {
        const workspace = normalizeWorkspace(raw[index]);
        if (workspace !== null)
            workspaces.push(workspace);
    }
    return workspaces;
}
