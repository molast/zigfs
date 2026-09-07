export function redactCommand(command, password) {
  let redacted = command.replace(
    /(--admin-password(?:=|\s+))(?:("[^"]*")|('[^']*')|(\S+))/g,
    '$1[REDACTED]',
  )
  if (password) redacted = redacted.split(password).join('[REDACTED]')
  return redacted
}
