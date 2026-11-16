"""Loaded inside LLDB by dump.py. No command input is taken from the target."""
import json
import os
import pathlib
import shlex
import time
import lldb


def capture(debugger, config):
    output=pathlib.Path(config['output'])
    target=debugger.CreateTarget(config['binary'])
    if not target.IsValid(): raise RuntimeError('Could not load executable')
    debugger.SetAsync(True)
    error=lldb.SBError()
    process=None
    result=dict(passed=False, mode='attach' if config.get('pid') else 'crash', threads=[], modules=[])
    try:
        if config.get('pid'):
            process=target.AttachToProcessWithID(debugger.GetListener(),config['pid'],error)
        else:
            launch=lldb.SBLaunchInfo(config.get('arguments',[]))
            launch.SetLaunchFlags(0)  # Preserve ASLR and avoid shell argument expansion.
            launch.SetWorkingDirectory(str(output))
            launch.AddOpenFileAction(1,str(output/'target.log'),False,True)
            launch.AddOpenFileAction(2,str(output/'target.log'),False,True)
            process=target.Launch(launch,error)
        if error.Fail() or not process.IsValid(): raise RuntimeError(str(error))
        deadline=time.monotonic()+config['timeout']
        while True:
            state=process.GetState()
            if state in (lldb.eStateStopped,lldb.eStateCrashed,lldb.eStateSuspended):
                reasons=[thread.GetStopReason() for thread in process]
                if config.get('pid') or any(r in (lldb.eStopReasonSignal,lldb.eStopReasonException) for r in reasons): break
                process.Continue()
            elif state in (lldb.eStateExited,lldb.eStateDetached,lldb.eStateInvalid):
                raise RuntimeError('Target exited without a captured crash')
            if time.monotonic()>deadline: raise RuntimeError('Capture timeout without a crash')
            time.sleep(.05)
        result['pid']=process.GetProcessID()
        for module in target.modules:
            header=module.GetObjectFileHeaderAddress()
            result['modules'].append(dict(path=str(module.GetFileSpec()),uuid=module.GetUUIDString(),load_address=header.GetLoadAddress(target),file_address=header.GetFileAddress()))
        for thread in process:
            frames=[]
            for frame in list(thread.frames)[:256]:
                pc=frame.GetPCAddress(); line=frame.GetLineEntry(); module=pc.GetModule()
                frames.append(dict(pc=frame.GetPC(),file_address=pc.GetFileAddress(),module=str(module.GetFileSpec()),
                                   module_uuid=module.GetUUIDString(),function=frame.GetFunctionName(),
                                   file=str(line.GetFileSpec()) if line.IsValid() else None,line=line.GetLine() if line.IsValid() else None))
            result['threads'].append(dict(id=thread.GetThreadID(),stop_reason=thread.GetStopDescription(512),frames=frames))
        response=lldb.SBCommandReturnObject()
        debugger.GetCommandInterpreter().HandleCommand('process save-core --style '+config['style']+' '+shlex.quote(str(output/'process.core')),response)
        (output/'core-save.log').write_text((response.GetOutput() or '')+(response.GetError() or ''))
        if not response.Succeeded() or not (output/'process.core').is_file() or (output/'process.core').stat().st_size==0:
            raise RuntimeError('Debugger could not save a core file; inspect core-save.log')
        result.update(passed=True,core='process.core',core_bytes=(output/'process.core').stat().st_size,style=config['style'])
    except Exception as error:
        result['error']=str(error)
    finally:
        if process and process.IsValid():
            # Never terminate a process the caller attached to.
            action=process.Detach() if config.get('pid') else process.Kill()
            if action.Fail():
                result.update(passed=False,cleanup_error=str(action))
        (output/'capture.json').write_text(json.dumps(result,indent=2)+'\n')


def __lldb_init_module(debugger, internal_dict):
    config=json.loads(pathlib.Path(os.environ['ZIGFS_CAPTURE_CONFIG']).read_text())
    capture(debugger,config)
