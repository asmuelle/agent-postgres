import os
import shutil

root_dir = "/Users/andreasmuller/experiments/appstore/apps/agent-postgres"

# Step 1: Content replacements
replacements = [
    ("McSshMacOS", "AgentPostgresMacOS"),
    ("McSshApp", "AgentPostgresApp"),
    ("McSsh", "AgentPostgres"),
    ("mcSsh", "agentPostgres"),
    ("midnight-ssh", "agent-postgres"),
    ("libagent_ssh", "libagent_postgres"),
    ("-lagent_ssh", "-lagent_postgres"),
    ("agent_ssh.swift", "agent_postgres.swift"),
    ("agent_ssh.h", "agent_postgres.h"),
    ("agent_sshFFI", "agent_postgresFFI"),
    ("agent-ssh", "agent-postgres"),
    ("Agent-Ssh.xcodeproj", "Agent-Postgres.xcodeproj"),
    ("AgentSsh", "AgentPostgres"),
]

ignored_dirs = {".git", "target", ".derivedData", "Mc-Ssh.xcodeproj", "Agent-Postgres.xcodeproj"}
valid_extensions = {".swift", ".yml", ".plist", ".toml", ".md", ".json", ".modulemap", ".sh", ".h"}
valid_names = {"justfile", "build.rs"}

# Iterate over all files and replace contents
for dirpath, dirnames, filenames in os.walk(root_dir):
    dirnames[:] = [d for d in dirnames if d not in ignored_dirs]
    for filename in filenames:
        ext = os.path.splitext(filename)[1]
        if ext in valid_extensions or filename in valid_names:
            filepath = os.path.join(dirpath, filename)
            try:
                with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                
                new_content = content
                modified = False
                for old, new in replacements:
                    if old in new_content:
                        new_content = new_content.replace(old, new)
                        modified = True
                
                if modified:
                    with open(filepath, 'w', encoding='utf-8') as f:
                        f.write(new_content)
                    print(f"Renamed content in file: {filepath}")
            except Exception as e:
                print(f"Error processing content in {filepath}: {e}")

# Step 2: Rename files containing McSsh or Mc-Ssh or agent_ssh
# We walk bottom-up so renaming nested paths doesn't invalidate parent paths
for dirpath, dirnames, filenames in os.walk(root_dir, topdown=False):
    # Skip ignored directories
    if any(ignored in dirpath for ignored in ignored_dirs):
        continue
    
    # Rename files
    for filename in filenames:
        new_filename = filename
        if "McSsh" in filename:
            new_filename = filename.replace("McSsh", "AgentPostgres")
        elif "agent_ssh" in filename:
            new_filename = filename.replace("agent_ssh", "agent_postgres")
        elif "AgentSsh" in filename:
            new_filename = filename.replace("AgentSsh", "AgentPostgres")
        
        if new_filename != filename:
            old_path = os.path.join(dirpath, filename)
            new_path = os.path.join(dirpath, new_filename)
            shutil.move(old_path, new_path)
            print(f"Renamed file: {old_path} -> {new_path}")

    # Rename directories
    for dirname in dirnames:
        if dirname in ignored_dirs:
            continue
        new_dirname = dirname
        if "McSsh" in dirname:
            new_dirname = dirname.replace("McSsh", "AgentPostgres")
        elif "AgentSsh" in dirname:
            new_dirname = dirname.replace("AgentSsh", "AgentPostgres")
        
        if new_dirname != dirname:
            old_path = os.path.join(dirpath, dirname)
            new_path = os.path.join(dirpath, new_dirname)
            shutil.move(old_path, new_path)
            print(f"Renamed dir: {old_path} -> {new_path}")
