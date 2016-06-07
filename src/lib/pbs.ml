(**************************************************************************)
(*    Copyright 2014, 2015:                                               *)
(*          Sebastien Mondet <seb@mondet.org>,                            *)
(*          Leonid Rozenberg <leonidr@gmail.com>,                         *)
(*          Arun Ahuja <aahuja11@gmail.com>,                              *)
(*          Jeff Hammerbacher <jeff.hammerbacher@gmail.com>               *)
(*                                                                        *)
(*  Licensed under the Apache License, Version 2.0 (the "License");       *)
(*  you may not use this file except in compliance with the License.      *)
(*  You may obtain a copy of the License at                               *)
(*                                                                        *)
(*      http://www.apache.org/licenses/LICENSE-2.0                        *)
(*                                                                        *)
(*  Unless required by applicable law or agreed to in writing, software   *)
(*  distributed under the License is distributed on an "AS IS" BASIS,     *)
(*  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or       *)
(*  implied.  See the License for the specific language governing         *)
(*  permissions and limitations under the License.                        *)
(**************************************************************************)

open Ketrew_pure
open Internal_pervasives
open Unix_io


open Long_running_utilities

module Run_parameters = struct
  type created = {
    host: Host.t;
    program: Program.t;
    shell: string;
    queue: string option;
    name: string option;
    email_user: [
        | `Never
        | `Always of string
      ];
    wall_limit: [
        | `Hours of float
      ];
    processors: int;
  } [@@deriving yojson]
  type running = {
    pbs_job_id: string;
    playground: Path.t;
    script: Monitored_script.t;
    created: created;
  } [@@deriving yojson]
  type t = [
    | `Created of created
    | `Running of running
  ] [@@deriving yojson]
end
type run_parameters = Run_parameters.t
include Json.Versioned.Of_v0(Run_parameters)
open Run_parameters

let name = "PBS"
let create
    ?(host=Host.tmp_on_localhost)
    ?queue ?name ?(wall_limit=`Hours 24.) ?(processors=1) ?(email_user=`Never)
    ?(shell="/usr/bin/env bash")
    program =
  `Long_running (
    "PBS",
    `Created {host; program; queue; name;
              email_user; shell; wall_limit; processors}
    |> serialize)

let markup =
  let open Display_markup in
  let created {host; program; shell; queue; name;
               email_user; wall_limit; processors} = [
    "Host", Host.markup host;
    "Program", Program.markup program;
    "Shell", command shell;
    "Queue", option ~f:text queue;
    "Name", option ~f:text name;
    "Email-user",
    begin match email_user with
    | `Never -> text "Never"
    | `Always e -> textf "Always: %S" e
    end;
    "Wall-Limit",
    begin match wall_limit with
    | `Hours f -> time_span (f *. 3600.)
    end;
    "Processors", textf "%d" processors;
  ] in
  function
  | `Created c ->
    description_list @@ ("Status", text "Created") :: created c
  | `Running rp ->
    description_list [
      "Status", text "Activated";
      "Created as", description_list (created rp.created);
      "PBS-ID", text rp.pbs_job_id;
      "Playground", path (Path.to_string rp.playground);
    ]

let log rp = ["PBS", Display_markup.log (markup rp)]

let start rp  ~host_io =
  match rp with
  | `Running _ ->
    fail_fatal "Wrong state: already running"
  | `Created created ->
    begin
      fresh_playground_or_fail ~host_io created.host
      >>= fun playground ->
      let script = Monitored_script.create ~playground created.program in
      let monitored_script_path = script_path ~playground in
      Host_io.ensure_directory host_io ~host:created.host ~path:playground
      >>= fun () ->
      let out = out_file_path ~playground in
      let err = err_file_path ~playground in
      let opt o ~f = Option.value_map ~default:[] o ~f:(fun s -> [f s]) in
      let resource_list =
        match created.wall_limit with
        | `Hours h ->
          let hr = floor (abs_float h) in
          let min = floor ((abs_float h -. hr) *. 60.) in
          fmt "nodes=1:ppn=%d,walltime=%02d:%02d:00"
            created.processors (int_of_float hr) (int_of_float min)
      in
      let content =
        String.concat ~sep:"\n" (List.concat [
            [fmt "#! %s" created.shell];
            begin match created.email_user with
            | `Never -> []
            | `Always email -> [
                fmt "#PBS -m abe";
                fmt "#PBS -M %s" email;
              ]
            end;
            [fmt "#PBS -e %s" (Path.to_string err)];
            [fmt "#PBS -o %s" (Path.to_string out)];
            opt created.name ~f:(fmt "#PBS -N %s");
            opt created.queue ~f:(fmt "#PBS -q %s");
            [fmt "#PBS -l %s" resource_list];
            [Monitored_script.to_string script];
          ]) in
      Host_io.put_file ~content
        host_io ~host:created.host ~path:monitored_script_path
      >>= fun () ->
      let cmd = fmt "qsub %s" (Path.to_string_quoted monitored_script_path) in
      Host_io.get_shell_command_output host_io ~host:created.host cmd
      >>= fun (stdout, stderr) ->
      Log.(s "Cmd: " % s cmd %n % s "Out: " % s stdout %n
           % s "Err: " % s stderr @ verbose);
      let pbs_job_id = String.strip stdout in
      return (`Running { pbs_job_id; playground; script; created})
    end
    >>< classify_and_transform_errors

let additional_queries = function
| `Created _ -> [
    "ketrew-markup/status", Log.(s "Get the status as Markup");
  ]
| `Running _ ->
  [
    "ketrew-markup/status", Log.(s "Get the status as Markup");
    "stdout", Log.(s "PBS output file");
    "stderr", Log.(s "PBS error file");
    "log", Log.(s "Monitored-script `log` file");
    "script", Log.(s "Monitored-script used");
    "qstat", Log.(s "Call `qstat -f1 <ID>`");
  ]

let query run_parameters ~host_io item =
  match run_parameters with
  | `Created _ ->
    begin match item with
    | "ketrew-markup/status" ->
      return (markup run_parameters |> Display_markup.serialize)
    | other -> fail Log.(s "not running")
    end
  | `Running rp ->
    begin match item with
    | "ketrew-markup/status" ->
      return (markup run_parameters |> Display_markup.serialize)
    | "log" ->
      let log_file = Monitored_script.log_file rp.script in
      Host_io.grab_file_or_log host_io ~host:rp.created.host log_file
    | "stdout" ->
      let out_file = out_file_path ~playground:rp.playground in
      Host_io.grab_file_or_log host_io ~host:rp.created.host out_file
    | "stderr" ->
      let err_file = err_file_path ~playground:rp.playground in
      Host_io.grab_file_or_log host_io ~host:rp.created.host err_file
    | "script" ->
      let monitored_script_path = script_path ~playground:rp.playground in
      Host_io.grab_file_or_log
        host_io ~host:rp.created.host monitored_script_path
    | "qstat" ->
      begin Host_io.get_shell_command_output host_io ~host:rp.created.host
          (fmt "qstat -f1 %s" rp.pbs_job_id)
        >>< function
        | `Ok (o, _) -> return o
        | `Error e ->
          fail Log.(s "Command `qstat -f1 <ID>` failed: " % s (Error.to_string e))
      end
    | other -> fail Log.(s "Unknown query: " % sf "%S" other)
    end

let update rp ~host_io =
  match rp with
  | `Created _ -> fail_fatal "not running"
  | `Running run as run_parameters ->
    begin
      get_log_of_monitored_script ~host_io ~host:run.created.host
        ~script:run.script
      >>= fun log_opt ->
      begin match Option.bind log_opt  List.last with
      | Some (`Success date) ->
        return (`Succeeded run_parameters)
      | Some (`Failure (date, label, ret)) ->
        return (`Failed (run_parameters, fmt "%s returned %s" label ret))
      | None | Some _->
        Host_io.execute host_io ~host:run.created.host
          ["qstat"; "-f1"; run.pbs_job_id]
        >>= fun return_obj ->
        begin match return_obj#exited with
        | 0 ->
          let job_state =
            String.split ~on:(`Character '\n') return_obj#stdout
            |> List.find_map ~f:(fun line ->
                String.split line ~on:(`Character '=')
                |> List.map ~f:String.strip
                |> (function
                  | ["job_state"; state] ->
                    begin match state with
                    | "Q" (* queued *)
                    | "E" (* exiting *)
                    | "H" (* held *)
                    | "T" (* moved *)
                    | "W" (* waiting *)
                    | "S" (* suspended *)
                    | "R" -> Some (state, `Running)
                    | "C" -> Some (state, `Completed)
                    | other ->
                      Log.(s "Can't understand job_state: " % s other @ warning);
                      None
                    end
                  | other -> None)
              )
          in
          begin match job_state with
          | Some (state, `Running) ->
            return (`Still_running run_parameters)
          | Some (state, `Completed) ->
            (* We get the log again to ensure the job did not between the
               previous check and the `qstat` one *)
            get_log_of_monitored_script ~host_io ~host:run.created.host
              ~script:run.script
            >>= fun log_opt ->
            begin match Option.bind log_opt  List.last with
            | Some (`Success date) ->
              return (`Succeeded run_parameters)
            | _ ->
              return (`Failed (run_parameters,
                               fmt "PBS status: %S + log: not success" state))
            end
          | None ->
            return (`Failed (run_parameters, fmt "PBS status: None"))
          end
        | other ->
          return (`Failed (run_parameters,
                           fmt "log says not finished; qstat returned %d" other))
        end
      end
    end
    >>< classify_and_transform_errors

let kill run_parameters ~host_io =
  begin match run_parameters with
  | `Created _ -> fail_fatal "not running"
  | `Running run as run_parameters ->
    begin
      let cmd = fmt "qdel %s" run.pbs_job_id in
      Host_io.get_shell_command_output host_io ~host:run.created.host cmd
      >>= fun (_, _) ->
      return (`Killed run_parameters)
    end
  end
  >>< classify_and_transform_errors
