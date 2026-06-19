const { join } = require("path");
const projectRoot = "C:\\Users\\Administrator\\Documents\\remed\\backend";
const nodeRoot = "C:\\Program Files\\nodejs\\";

module.exports = {
  apps: [
    {
      name: "remed",
      cwd: projectRoot,
      interpreter: join(nodeRoot, "node.exe"),
      script: join(projectRoot, "dist\\app.cjs"),
      node_args: ["--max-old-space-size=8192"],
      // ? Alternative config:
      // interpreter: "none",
      // script: join(nodeRoot, "npm.cmd"),
      // args: ["run", "normal"],
      out_file: "C:\\pm2\\logs\\remed-out.log",
      error_file: "C:\\pm2\\logs\\remed-error.log",
      merge_logs: true,
      time: true,
      autorestart: true,
      restart_delay: 5000,
      env : {
        PORT : 80,
        HL7_PORT : 9999,
        ASTM_PORT: 5000,
        UPLOADS_DIR: "C:\\remed_uploads",
        BACKUPS_DIR: "C:\\remed_backups",
        SQLITE_DB_PATH: "C:\\remed_data\\remed.db"
      }
    }
  ]
};
