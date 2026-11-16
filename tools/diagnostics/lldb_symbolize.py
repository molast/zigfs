"""Offline address resolver loaded by symbolize.py; never launches a process."""
import json
import os
import pathlib
import lldb


def __lldb_init_module(debugger, internal_dict):
    config=json.loads(pathlib.Path(os.environ['ZIGFS_SYMBOLIZE_CONFIG']).read_text())
    target=debugger.CreateTarget(config['binary'])
    rows=[]
    for address in config['addresses']:
        resolved=target.ResolveFileAddress(address)
        function=resolved.GetFunction()
        symbol=resolved.GetSymbol()
        line=resolved.GetLineEntry()
        name=function.GetName() if function.IsValid() else symbol.GetName() if symbol.IsValid() else None
        rows.append(dict(file_address=address,function=name,file=str(line.GetFileSpec()) if line.IsValid() else None,
                         line=line.GetLine() if line.IsValid() else None,resolved=bool(name)))
    pathlib.Path(config['output']).write_text(json.dumps(rows,indent=2)+'\n')
