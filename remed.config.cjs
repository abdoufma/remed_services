const { join } = require("path");
const projectRoot = "C:\\Users\\Administrator\\Documents\\remed\\backend";
const nodeRoot = "C:\\Program Files\\nodejs\\";

module.exports = {
  apps: [
    {
      name: "remed",
      cwd: projectRoot,
      interpreter: join(nodeRoot, "node.exe"),
      script: join(projectRoot, "dist\\app.js"),
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
        HL7_PORT : 9000,
        ASTM_PORT : 5000,
      }
    }
  ]
};