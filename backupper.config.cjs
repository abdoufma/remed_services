const { join } = require("path");
const projectRoot = "C:\\Users\\Administrator\\Documents\\tests\\remed_backupper";
const nodeRoot = "C:\\Program Files\\nodejs\\";

module.exports = {
  apps: [
    {
      name: "backupper",
      cwd: projectRoot,
      interpreter: join(nodeRoot, "node.exe"),
      script: join(projectRoot, "periodic.js"),
      node_args: ["--env-file=.env"],
      // ? Alternative config:
      // interpreter: "none",
      // script: join(nodeRoot, "npm.cmd"),
      // args: ["run", "periodic"],
      out_file: "C:\\pm2\\logs\\backupper-out.log",
      error_file: "C:\\pm2\\logs\\backupper-error.log",
      merge_logs: true,
      time: true,
      autorestart: true,
      restart_delay: 5000
    }
  ]
};