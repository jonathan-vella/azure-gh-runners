import { execFile } from "node:child_process";

export const managedTag = "ghr-managed";
export const adminUsername = "ghradmin";
const expiryGraceMinutes = 15;
const iso = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

const kinds = {
  "microsoft.compute/virtualmachines": { order: 0, label: "vm", delete: ["vm", "delete", "--yes"] },
  "microsoft.network/networkinterfaces": { order: 1, label: "nic", delete: ["network", "nic", "delete"] },
  "microsoft.compute/disks": { order: 2, label: "disk", delete: ["disk", "delete", "--yes"] },
};

export function computeExpiresUtc(nowMs, jobTimeoutMinutes) {
  const expires = new Date(nowMs + (jobTimeoutMinutes + expiryGraceMinutes) * 60_000);
  return expires.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function parseExpiry(value) {
  if (typeof value !== "string" || !iso.test(value)) return Number.NaN;
  return Date.parse(value);
}

export function resourceGroupOf(resourceId) {
  const match = /^\/subscriptions\/[^/]+\/resourceGroups\/([^/]+)\//i.exec(resourceId ?? "");
  return match ? match[1].toLowerCase() : undefined;
}

// Pure selection: only this system's expired VMs/NICs/disks in the configured resource group, VMs first.
export function selectExpired(resources, { resourceGroup, nowMs }) {
  const group = resourceGroup.toLowerCase();
  return (resources ?? [])
    .filter((resource) => {
      const kind = kinds[String(resource?.type ?? "").toLowerCase()];
      if (!kind || typeof resource.id !== "string") return false;
      if (resourceGroupOf(resource.id) !== group) return false;
      if (resource.tags?.[managedTag] !== "true") return false;
      const expires = parseExpiry(resource.tags?.expiresUtc);
      return Number.isFinite(expires) && expires <= nowMs;
    })
    .sort((a, b) => kinds[a.type.toLowerCase()].order - kinds[b.type.toLowerCase()].order)
    .map((resource) => ({ id: resource.id, type: resource.type, tags: resource.tags }));
}

export function buildCustomData({ jitConfig, policy, expiresUtc }) {
  return JSON.stringify({ version: 1, jitConfig, policy, expiresUtc });
}

export function workerTags({ consumer, runId, expiresUtc }) {
  return { [managedTag]: "true", consumer, runId, expiresUtc };
}

export function workerNames(vmName) {
  return { vm: vmName, nic: `nic-${vmName}`, disk: `osdisk-${vmName}` };
}

function isNotFound(text) {
  return /ResourceNotFound|ResourceGroupNotFound|NotFound|was not found|could not be found|does not exist/i.test(text);
}

export function createAzRunner({ redact = (text) => text, execFileImpl = execFile, timeoutMs = 20 * 60_000 } = {}) {
  return function az(args, { parse = true } = {}) {
    return new Promise((resolve, reject) => {
      execFileImpl(
        "az",
        [...args, "--only-show-errors", "--output", "json"],
        {
          timeout: timeoutMs,
          maxBuffer: 16 * 1024 * 1024,
          env: { ...process.env, AZURE_CORE_COLLECT_TELEMETRY: "false", AZURE_CORE_NO_COLOR: "true" },
        },
        (error, stdout, stderr) => {
          if (error) {
            // Only the command words are echoed; argument values (VM password, paths) are never included.
            const command = args.filter((arg) => !arg.startsWith("-")).slice(0, 2).join(" ");
            const detail = redact(String(stderr || error.message)).trim().slice(0, 500);
            const failure = new Error(`az ${command} failed: ${detail}`);
            failure.notFound = isNotFound(String(stderr));
            reject(failure);
            return;
          }
          const text = String(stdout).trim();
          if (!parse || !text) {
            resolve(text || null);
            return;
          }
          try {
            resolve(JSON.parse(text));
          } catch {
            reject(new Error(`az ${args[0]} returned unparseable output.`));
          }
        },
      );
    });
  };
}

export function createWorkerOps({ az, resourceGroup, vmssName, imageId, subnetId, clientId }) {
  async function deleteIfPresent(args) {
    try {
      await az(args, { parse: false });
      return true;
    } catch (error) {
      if (error.notFound) return false;
      throw error;
    }
  }

  return {
    async login() {
      await az(["login", "--identity", "--client-id", clientId], { parse: false });
    },

    async listManaged() {
      const query = "[].{id:id,type:type,tags:tags}";
      const lists = await Promise.all([
        az(["vm", "list", "--resource-group", resourceGroup, "--query", query]),
        az(["network", "nic", "list", "--resource-group", resourceGroup, "--query", query]),
        az(["disk", "list", "--resource-group", resourceGroup, "--query", query]),
      ]);
      return lists.flat();
    },

    async deleteResource(resource) {
      const kind = kinds[String(resource.type).toLowerCase()];
      if (!kind || resourceGroupOf(resource.id) !== resourceGroup.toLowerCase()) {
        throw new Error("Refusing to delete a resource outside the worker resource group or kinds.");
      }
      return deleteIfPresent([...kind.delete, "--ids", resource.id]);
    },

    async createWorker({ vmName, tags, customDataFile, adminPassword, vmSize }) {
      const names = workerNames(vmName);
      const tagArgs = Object.entries(tags).map(([key, value]) => `${key}=${value}`);
      await az([
        "network", "nic", "create",
        "--resource-group", resourceGroup,
        "--name", names.nic,
        "--subnet", subnetId,
        "--tags", ...tagArgs,
      ], { parse: false });
      await az([
        "vm", "create",
        "--resource-group", resourceGroup,
        "--name", names.vm,
        "--vmss", vmssName,
        "--image", imageId,
        "--size", vmSize,
        "--nics", names.nic,
        "--nic-delete-option", "Delete",
        "--os-disk-name", names.disk,
        "--os-disk-delete-option", "Delete",
        "--storage-sku", "Premium_LRS",
        "--security-type", "TrustedLaunch",
        "--enable-secure-boot", "true",
        "--enable-vtpm", "true",
        "--admin-username", adminUsername,
        "--admin-password", adminPassword,
        "--custom-data", customDataFile,
        "--tags", ...tagArgs,
      ], { parse: false });
      try {
        const diskId = await az([
          "vm", "show", "--resource-group", resourceGroup, "--name", names.vm,
          "--query", "storageProfile.osDisk.managedDisk.id",
        ]);
        if (typeof diskId === "string" && diskId) {
          await az(["disk", "update", "--ids", diskId, "--set", `tags=${JSON.stringify(tags)}`], { parse: false });
        }
      } catch {
        // The VM was created with delete-on-VM-delete for the disk; a tagging failure must not fail the job.
      }
    },

    async powerState(vmName) {
      try {
        const state = await az([
          "vm", "get-instance-view", "--resource-group", resourceGroup, "--name", vmName,
          "--query", "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]",
        ]);
        return typeof state === "string" ? state : "unknown";
      } catch (error) {
        if (error.notFound) return "deleted";
        throw error;
      }
    },

    // Deletes only this run's VM, NIC and OS disk, identified by their unique names, and only when the
    // VM still carries this run's managed tags.
    async deleteWorker({ vmName, runId }) {
      const names = workerNames(vmName);
      const failures = [];
      try {
        const vm = await az(["vm", "show", "--resource-group", resourceGroup, "--name", names.vm, "--query", "{id:id,tags:tags}"])
          .catch((error) => {
            if (error.notFound) return null;
            throw error;
          });
        if (vm) {
          if (vm.tags?.[managedTag] !== "true" || vm.tags?.runId !== runId) {
            throw new Error("Refusing to delete a VM that does not carry this run's managed tags.");
          }
          await deleteIfPresent(["vm", "delete", "--ids", vm.id, "--yes"]);
        }
      } catch (error) {
        failures.push(error);
      }
      for (const args of [
        ["network", "nic", "delete", "--resource-group", resourceGroup, "--name", names.nic],
        ["disk", "delete", "--resource-group", resourceGroup, "--name", names.disk, "--yes"],
      ]) {
        try {
          await deleteIfPresent(args);
        } catch (error) {
          failures.push(error);
        }
      }
      if (failures.length > 0) {
        throw new Error(`Worker cleanup failed: ${failures.map((failure) => failure.message).join("; ")}`);
      }
    },
  };
}
