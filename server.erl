-module(server).
-include("header.hrl").
-import(lists, [nth/2, member/2, append/2, delete/2]).
-import(tateti, [make_play/3]).
-export([start/0, open_socket/1, dispatcher/1, master/3]).
-export([pstat/0, pbalance/1, request_node/0]).
-export([psocket/3, pcomando/3, pupdater/1]).
-export([lsgRequest/2, broadcast/2, send_to_registered/3, delete_player/4, find_min/1]).


% Inicializamos el server.
start() ->
  MasterPid = spawn(?MODULE, master, [[], maps:new(), 0]),
  register(master, MasterPid),
  PBPid = spawn(?MODULE, pbalance, [maps:new()]),
  register(pbalance, PBPid),
  PSPid = spawn(?MODULE, pstat, []),
  register(pstat, PSPid),
  LSocket = open_socket(?PORT),
  spawn(?MODULE, dispatcher, [LSocket]),
  ok.

% Abre el socket en el primer puerto disponible que se encuentre a partir
% del default definido en el header.
open_socket(Port) ->
  case gen_tcp:listen(Port, [binary, {packet, 0}, {active, false}]) of
    {ok, LSocket} -> io:format("Abriendo socket y escuchando en puerto ~p ~n", [Port]), 
                     LSocket;
    {error, eaddrinuse} -> io:format("Puerto ~p en uso~n", [Port]),
                           open_socket(Port + 1)
  end.

% Envía una actualización a todos los clientes pertinentes
broadcast([], _) -> ok;
broadcast([HdUpdater | Tl], Update) ->
  HdUpdater ! Update,
  broadcast(Tl, Update).

% Función auxiliar para listar los juegos disponibles.
lsgRequest([], _) -> [];
lsgRequest([Hd | Tl], CMDId) ->
  {master, Hd} ! {lsg, CMDId, self()},
  receive
    {ok, CMDId, Lsg} -> append(Lsg, lsgRequest(Tl, CMDId))
  end.

% Envía el mensaje dado al hilo registrado en el atomo dado a los nodos dados
send_to_registered(_, [], _) -> ok;
send_to_registered(Atom, [Hd | Tl], Request) ->
  {Atom, Hd} ! Request,
  send_to_registered(Atom, Tl, Request).

% Elimina un jugador de todos los juegos que participe (como jugador).
delete_player(_, _, [], Games) -> Games;
delete_player(Name, Updater, [Hd | Tl], Games) ->
  Game = maps:get(Hd, Games),
  if 
  (Game#game.p1 == Name) or (Game#game.p2 == Name) ->
    broadcast(Game#game.updaters, {upd, leave, Name, Hd}),
    NGames = maps:remove(Hd, Games),
    delete_player(Name, Updater, Tl, NGames);
  true -> 
    NGame = Game#game{obs = delete(Name, Game#game.obs), updaters = delete(Updater, Game#game.updaters)},
    NGames = maps:put(Hd, NGame, Games),
    delete_player(Name, Updater, Tl, NGames)
  end. 

% Envía a intervalos regulares la información de carga del nodo actual 
% al resto de los nodos.
pstat()->
  send_to_registered(pbalance,[node() | nodes()], {status, node(), statistics(run_queue)}),
  timer:sleep(5000),
  pstat().

% Función auxiliar, se encarga de pedirle al proceso pbalance
% el nodo con menor carga.
request_node()->
  pbalance ! {node, self()},
  receive
    Node -> Node
  end.

% Toma un mapa donde se guarda la información de carga de cada nodo
% y devuelve el que tiene carga mínima.
find_min(Map)->
  Stats = maps:to_list(Map),
  Sorted = lists:sort(fun(NodeA, NodeB) -> (element(2, NodeA) =< element(2, NodeB)) end, Stats),
  element(1, nth(1, Sorted)).

% Proceso que se encarga de recibir la información de carga de los nodos
% y almacena dicha info en un mapa. Además, atiende los pedidos de psocket
% cuando se requiere el nodo que tenga menos carga.
pbalance(StatusMap) ->
  receive
    {status, Node, Stat} ->
        pbalance(maps:put(Node, Stat, StatusMap));
    {node, PID} -> 
      PID ! find_min(StatusMap),
      pbalance(StatusMap) 
  end.

% Acepta las conexiones entrantes y crea un hilo que se encargará 
% de los pedidios de ese cliente.
dispatcher(LSocket) -> 
  {ok, Socket} = gen_tcp:accept(LSocket),
  io:format("Cliente conectado en socket ~p ~n", [Socket]),
  Updater = spawn(?MODULE, pupdater, [Socket]),
  spawn(?MODULE, psocket, [Socket, undefined, Updater]),
  dispatcher(LSocket).

% Hilo que atiende los pedidos de un cliente determinado.
psocket(Socket, undefined, Updater) ->
  case gen_tcp:recv(Socket, 0) of
    {ok, Packet} ->
      Request = binary_to_term(Packet),
      case Request of
        {con, Name} -> 
          case pcomando({con, {Name, node()}}, undefined, Updater) of
            {error, _} -> psocket(Socket, undefined, Updater);
            ok -> psocket(Socket, {Name, node()}, Updater)
          end;
        _ -> gen_tcp:send(Socket, term_to_binary({error, "Definí tu nombre primero"}))
      end;
    {error, closed} ->
      io:format("Cliente en socket ~p desconectado ~n", [Socket]),
      Updater ! bye,
      ok
  end;
psocket(Socket, Name, Updater) ->
  case gen_tcp:recv(Socket, 0) of
    {ok, Packet} ->
      Request = binary_to_term(Packet),
      spawn(request_node(), ?MODULE, pcomando, [Request, Name, Updater]),
      psocket(Socket, Name, Updater);
    {error, closed} ->
      io:format("Cliente ~p en socket ~p desconectado ~n", [Name, Socket]),
      Updater ! bye,
      pcomando(disconnect, Name, Updater)
  end.

% Hilo de comunicación del servidor al cliente para actualizar estados y
% responder peticiones
pupdater(Socket) ->
  receive 
    bye -> ok;
    Update -> gen_tcp:send(Socket, term_to_binary(Update)),
              pupdater(Socket)
  end.

% Agrega un nuevo usuario al servidor.
pcomando({con, NewName}, Name, Updater) ->
  if 
    Name /= undefined -> Updater ! {error, "Ya tenés un nombre definido"};
    true -> 
      master ! {con, NewName, self()},
      receive
        Response -> Updater ! Response,
                    Response
      end
  end;
% Lista los juegos disponibles.
pcomando({lsg, CMDId}, _, Updater) ->
  Lsg = lsgRequest([node() | nodes()], CMDId),
  Updater ! {ok, lsg, CMDId, Lsg};
% Inicia nuevo juego.
pcomando({new, CMDId}, Name, Updater) -> 
  master ! {new, CMDId, Name, Updater, self()},
  receive
    Response -> Updater ! Response
  end;
% Acepta un juego.
pcomando({acc, CMDId, {Count, Node}}, Name, Updater) -> 
  {master, Node} ! {acc, CMDId, {Count, Node}, Name, Updater, self()},
  receive
    {error, CMDId, Reason} -> Updater ! {error, CMDId, Reason};
    {ok, CMDId, Game} -> Updater ! {ok, CMDId},
                         timer:sleep(100),
                         broadcast(Game#game.updaters, {upd, start, {Count, Node}, Game})                                  
  end;
% Abandonar una partida en especifico.
pcomando({pla, CMDId, {Count, Node}, leave}, Name, Updater)->
  {master, Node} ! {pla, CMDId, {Count, Node}, leave, Name, self()},
  receive
    Response -> Updater ! Response
  end;
% Hacer una jugada.
pcomando({pla, CMDId, {Count, Node}, Play}, Name, Updater) -> 
  {master, Node} ! {pla, CMDId, {Count, Node}, Play, Name, self()},
  receive
    {error, CMDId, Reason} -> Updater ! {error, CMDId, Reason};
    {ok, CMDId, Game, Result} -> Updater ! {ok, CMDId},
                                 timer:sleep(100),
                                 broadcast(Game#game.updaters, {upd, pla, Name, {Count, Node}, Game, Result});
    {ok, CMDId, Game} -> Updater ! {ok, CMDId},
                         timer:sleep(100),
                         broadcast(Game#game.updaters, {upd, pla, Name, {Count, Node}, Game})
  end;
% Observar un juego
pcomando({obs, CMDId, {Count, Node}}, Name, Updater) -> 
  {master, Node} ! {obs, CMDId, {Count, Node}, Name, Updater, self()},
  receive
    Response -> Updater ! Response
  end;
% Dejar de observar un juego.
pcomando({lea, CMDId, {Count, Node}}, Name, Updater) -> 
  {master, Node} ! {lea, CMDId, {Count, Node}, Name, Updater, self()},
  receive
    Response -> Updater ! Response
  end;
% Abandonar todos los juegos en los que el usuario participe.
pcomando(bye, Name, Updater) ->
  master ! {bye, Name, Updater, self()},
  send_to_registered(master, nodes(), {bye, Name, Updater, self()}),
  receive
    Response -> Updater ! Response
  end;
% Termina la conexión.
pcomando(disconnect, Name, Updater) ->
  master ! {bye, Name, Updater, self()},
  send_to_registered(master, nodes(), {bye, Name, Updater, self()}),
  receive
    _ -> ok
  end;
% Pattern comodín, en caso de que se use otro cliente y se ingrese un comando
% inválido o con sintaxis inválida.
pcomando(_, _, Updater) ->
  Updater ! {error, -1, "Comando inválido"}.

% Master loop que se encarga de mantener actualizada la info 
% de las partidas y los jugadores.
master(Players, Games, Count) -> 
  receive
    % Ingresa nuevo usuario.
    {con, Name, PID} -> 
      case member(Name, Players) of
        true -> PID ! {error, "Este nombre ya está en uso"},
                master(Players, Games, Count);
        false -> PID ! ok,
                 master([Name | Players], Games, Count)
      end;

    % Se pide una lista de todos los juegos disponibles.
    {lsg, CMDId, PID} -> 
      IDs = maps:keys(Games),
      Lsg = lists:foldl(fun(ID, List) ->
                          Game = maps:get(ID, Games),
                          [{ID, Game#game.p1, Game#game.p2, Game#game.obs}] ++ List 
                          end, 
                        [], IDs),
      PID ! {ok, CMDId, Lsg},
      master(Players, Games, Count);

    % Crea un nuevo juego.
    {new, CMDId, Name, Updater, PID} -> 
      GameId = {Count, node()},
      Game = #game{p1 = Name, obs = [], moves = 0, updaters = [Updater]}, 
      NGames = maps:put(GameId, Game, Games),
      PID ! {ok, new, CMDId, GameId},
      master(Players, NGames, Count + 1);

    % Acepta un juego.
    {acc, CMDId, GameId, Name, Updater, PID} ->
      case maps:find(GameId, Games) of
        error -> PID ! {error, CMDId, "Juego no encontrado"},
                 master(Players, Games, Count);
        {ok, Game} ->
          IsObs = member(Name, Game#game.obs),
          if 
            IsObs ->
              PID ! {error, CMDId, "No podés jugar una partida que estás observando, primero deja de observar"},
              master(Players, Games, Count);
            Game#game.p1 == Name ->
              PID ! {error, CMDId, "No podés jugar contra vos mismo"},
              master(Players, Games, Count);
            Game#game.p2 /= undefined -> 
              PID ! {error, CMDId, "El juego ya está en curso"},
              master(Players, Games, Count);
            true -> 
              PList = [Game#game.p1, Name], % Elegimos de quien es el primer turno aleatoriamente
              Index = rand:uniform(length(PList)),
              NGame = Game#game{p2 = Name, board = ?CLEANBOARD, turn = nth(Index, PList), updaters = [Updater | Game#game.updaters]},
              NGames = maps:update(GameId, NGame, Games),
              PID ! {ok, CMDId, NGame},
              master(Players, NGames, Count)
          end
      end;
    
    % Abandonar un juego
    {pla, CMDId, GameId, leave, Name, PID} -> 
      case maps:find(GameId, Games) of
        error -> 
          PID ! {error, CMDId, "Juego no encontrado"},                 
          master(Players, Games, Count);
        {ok, Game} ->
          if 
            (Game#game.p1 == Name) or (Game#game.p2 == Name) ->
              broadcast(Game#game.updaters, {upd, leave, Name, GameId}),
              NGames = maps:remove(GameId, Games),
              PID ! {ok, CMDId},
              master(Players, NGames, Count);
            true ->
              PID ! {error, CMDId, "No estás participando de este juego"},
              master(Players, Games, Count)
          end
      end;
    
    % Realizar una jugada.
    {pla, CMDId, GameId, Play, Name, PID} -> 
      case maps:find(GameId, Games) of
        error -> 
          PID ! {error, CMDId, "Juego no encontrado"},                 
          master(Players, Games, Count);
        {ok, Game} ->
          if 
            Game#game.p2 /= undefined ->            
              case make_play(Game, Play, Name) of
                {error, Reason} ->
                  PID ! {error, CMDId, Reason},
                  master(Players, Games, Count);
                {Result, NGame} -> 
                  NGames = maps:remove(GameId, Games),
                  PID ! {ok, CMDId, NGame, Result},
                  master(Players, NGames, Count);
                NGame ->
                  NGames = maps:update(GameId, NGame, Games),
                  PID ! {ok, CMDId, NGame},
                  master(Players, NGames, Count)
              end;
            true ->
              PID ! {error, CMDId, "El juego todavía no comenzó"},
              master(Players, Games, Count)
          end
      end;

    % Observar una partida.
    {obs, CMDId, GameId, Name, Updater, PID} ->
      case maps:find(GameId, Games) of
        error -> 
          PID ! {error, CMDId, "Juego no encontrado"},                 
          master(Players, Games, Count);
        {ok, Game} -> 
          case member(Name, Game#game.obs) of
            true -> 
              PID ! {error, CMDId, "Ya estás observando este juego"},
              master(Players, Games, Count);
            false ->
              if 
                (Game#game.p1 /= Name) and (Game#game.p2 /= Name) ->
                  NGame = Game#game{obs = [Name | Game#game.obs], updaters = [Updater | Game#game.updaters]},
                  NGames = maps:update(GameId, NGame, Games),
                  PID ! {ok, obs, CMDId, GameId, Game},          
                  master(Players, NGames, Count);
                true ->
                  PID ! {error, CMDId, "Estás participando en este juego"},
                  master(Players, Games, Count)
                end
          end
      end;

    % Dejar de observar una partida.
    {lea, CMDId, GameId, Name, Updater, PID} -> 
      case maps:find(GameId, Games) of
        error ->
          PID ! {error, CMDId, "Juego no encontrado"},
          master(Players, Games, Count);
        {ok, Game} -> 
          case member(Name, Game#game.obs) of
            false -> 
              PID ! {error, CMDId, "No estás observando este juego"},
              master(Players, Games, Count);
            true ->
              NGame = Game#game{obs = delete(Name, Game#game.obs), updaters = delete(Updater, Game#game.updaters)},
              NGames = maps:update(GameId, NGame, Games),
              PID ! {ok, CMDId}, 
              master(Players, NGames, Count)
          end
      end;
    % Abandona todos los juegos en los que participe.
    {bye, Name, Updater, PID} ->
      NGames = delete_player(Name, Updater, maps:keys(Games), Games),
      master(delete(Name, Players), NGames, Count),
      PID ! ok
  end.