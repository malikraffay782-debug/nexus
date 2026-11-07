package com.nexus.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files

class ProjectMountException(message: String) : Exception(message)

/**
 * Validated host -> guest mount for one project.
 * Dart only sends projectId; Kotlin builds and validates the host path.
 */
class ProjectMount private constructor(
    val projectId: String,
    val hostDir: File,
) {
    val bindSpec: String get() = "${hostDir.path}:$GUEST_DIR"

    fun prootArgs(): List<String> = listOf("-b", bindSpec, "-w", GUEST_DIR)

    fun guestCommand(): List<String> = listOf(
        "env",
        "PYTHONUNBUFFERED=1",
        "PYTHONDONTWRITEBYTECODE=1",
        "python3",
        GUEST_SCRIPT,
    )

    companion object {
        const val GUEST_DIR = "/home/project"
        const val ENTRY_REL = "src/main.py"
        const val GUEST_SCRIPT = "$GUEST_DIR/$ENTRY_REL"

        private val ID_RE = Regex("^[A-Za-z0-9_-]{1,64}$")

        fun resolve(projectsRoot: File, projectId: String): ProjectMount {
            if (!ID_RE.matches(projectId)) {
                throw ProjectMountException("Invalid project id")
            }
            val rootCanon = try {
                projectsRoot.canonicalFile
            } catch (e: IOException) {
                throw ProjectMountException("Cannot resolve projects folder")
            }
            if (!rootCanon.isDirectory) {
                throw ProjectMountException("Projects folder not found")
            }

            val candidate = File(rootCanon, projectId)
            if (isSymlink(candidate)) {
                throw ProjectMountException("Project folder is a symlink")
            }
            if (!candidate.isDirectory) {
                throw ProjectMountException("Project folder not found")
            }

            val canon = try {
                candidate.canonicalFile
            } catch (e: IOException) {
                throw ProjectMountException("Cannot resolve project folder")
            }
            val parent = canon.parentFile
            if (parent == null || parent.canonicalFile != rootCanon || canon.name != projectId) {
                throw ProjectMountException("Project is outside the projects folder")
            }
            if (canon.path.contains(':') || canon.path.contains(',')) {
                throw ProjectMountException("Unsupported characters in project path")
            }

            checkEntry(canon)
            return ProjectMount(projectId, canon)
        }

        private fun checkEntry(projectDir: File) {
            val src = File(projectDir, "src")
            val script = File(src, "main.py")
            if (isSymlink(src) || isSymlink(script)) {
                throw ProjectMountException("src/main.py must not be a symlink")
            }
            if (!script.isFile) {
                throw ProjectMountException("src/main.py not found")
            }
            val sc = try {
                script.canonicalFile
            } catch (e: IOException) {
                throw ProjectMountException("Cannot resolve src/main.py")
            }
            if (!sc.path.startsWith(projectDir.path + File.separator)) {
                throw ProjectMountException("src/main.py is outside the project")
            }
        }

        fun ensureGuestMountPoint(rootfs: File) {
            val rootCanon = try {
                rootfs.canonicalFile
            } catch (e: IOException) {
                throw ProjectMountException("Cannot resolve runtime rootfs")
            }
            var cur = rootCanon
            for (part in listOf("home", "project")) {
                cur = File(cur, part)
                if (isSymlink(cur)) {
                    throw ProjectMountException("Guest mount point contains a symlink")
                }
            }
            if (!cur.exists() && !cur.mkdirs()) {
                throw ProjectMountException("Cannot create /home/project in runtime")
            }
            if (!cur.isDirectory) {
                throw ProjectMountException("/home/project is not a directory")
            }
        }

        internal fun isSymlink(f: File): Boolean {
            return try {
                if (Files.isSymbolicLink(f.toPath())) return true
                // Also treat a path whose parent chain differs after canonicalization
                // as unsafe (symlink parent escape).
                val abs = f.absoluteFile
                val canon = f.canonicalFile
                abs.path != canon.path && abs.name == canon.name
            } catch (_: Exception) {
                // Fail closed: treat unreadable paths as unsafe symlinks
                true
            }
        }
    }
}
