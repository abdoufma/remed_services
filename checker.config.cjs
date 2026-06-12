const { join } = require("path");
const projectRoot = "C:\\Users\\Administrator\\Documents\\tests\\remed_health_checker";
const nodeRoot = "C:\\Program Files\\nodejs\\";

module.exports = {
  apps: [
    {
      name: "health_checker",
      cwd: projectRoot,
      script: join(projectRoot, "index.js"),
      interpreter: join(nodeRoot, "node.exe"),
      node_args: "--env-file=.env",
      out_file: "C:\\pm2\\logs\\health_checker-out.log",
      error_file: "C:\\pm2\\logs\\health_checker-error.log",
      merge_logs: true,
      time: true,
      autorestart: true,
      restart_delay: 5000
    }
  ]
};