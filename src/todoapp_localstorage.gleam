import formal/form
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event

// MAIN ------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

// MODEL -----------------------------------------------------------------------

type Model {
  Model(todos: List(Todo), next_id: Int)
}

type Todo {
  Todo(id: Int, title: String, completed: Bool)
}

fn init(_) -> #(Model, Effect(Msg)) {
  let todos = []
  let next_id = 0

  // When our program first loads, we'll immediately dispatch an effect to read
  // any existing todos from local storage. Because this effect is synchronous,
  // it will run and return before the app renders.
  #(Model(todos:, next_id:), get_todos())
}

// UPDATE ----------------------------------------------------------------------

type Msg {
  LocalStorageReturnedTodos(Result(List(Todo), Nil))
  UserToggledTodo(id: Int, completed: Bool)
  UserCreatedTodo(Result(String, Nil))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    LocalStorageReturnedTodos(Error(_)) -> #(model, effect.none())
    LocalStorageReturnedTodos(Ok(todos)) -> {
      let next_id =
        list.fold(todos, model.next_id, fn(max, item) {
          case item.id >= max {
            True -> item.id + 1
            False -> max
          }
        })

      #(Model(todos:, next_id:), effect.none())
    }

    UserToggledTodo(id:, completed:) -> {
      let todos =
        list.map(model.todos, fn(item) {
          case item.id == id {
            True -> Todo(..item, completed:)
            False -> item
          }
        })

      #(Model(..model, todos:), set_todos(todos))
    }

    UserCreatedTodo(Error(_)) -> #(model, effect.none())

    UserCreatedTodo(Ok(title)) -> {
      let todos = list.append(model.todos, [Todo(model.next_id, title, False)])
      let next_id = model.next_id + 1

      #(Model(todos:, next_id:), set_todos(todos))
    }
  }
}

fn get_todos() -> Effect(Msg) {
  use dispatch <- effect.from

  let result =
    // Once we're inside a custom effect, we can call effectful functions like
    // `get_localstorage` directly. We've stepped "outside" of Lustre and don't
    // have to worry about pure functions anymore.
    result.try(get_localstorage("todos"), fn(dyn) {
      case decode.run(dyn, decode.list(todo_decoder())) {
        Ok(todos) -> Ok(todos)
        Error(_) -> Error(Nil)
      }
    })

  dispatch(LocalStorageReturnedTodos(result))
}

fn todo_decoder() -> Decoder(Todo) {
  use id <- decode.field("id", decode.int)
  use title <- decode.field("title", decode.string)
  use completed <- decode.field("completed", decode.bool)

  decode.success(Todo(id:, title:, completed:))
}

// Note: we provide a default implementation of the `get_localstorage/1`
// function that always fails. Where possible
// it’s good to provide an implementation for all
// of Gleam’s targets. This makes it much easier to run
// your code as a server component in the future.
@external(javascript, "./todoapp_localstorage.ffi.mjs", "get_localstorage")
fn get_localstorage(_key: String) -> Result(Dynamic, Nil) {
  Error(Nil)
}

// Not all effects will dispatch messages. Just like element's
// that dont dispatch events, it's good practice to annotate
// these effects using a generic `msg`
// type so they can be used in any context.
fn set_todos(todos: List(Todo)) -> Effect(msg) {
  use _ <- effect.from

  let json = json.array(todos, encode_todo)

  set_localstorage("todos", json.to_string(json))
}

fn encode_todo(item: Todo) -> Json {
  json.object([
    #("id", json.int(item.id)),
    #("title", json.string(item.title)),
    #("completed", json.bool(item.completed)),
  ])
}

@external(javascript, "./todoapp_localstorage.ffi.mjs", "set_localstorage")
fn set_localstorage(_key: String, _value: String) -> Nil {
  Nil
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("mx-auto w-full max-w-2xl space-y-8 p-32")], [
    html.h1([attribute.class("text-2xl font-semibold")], [html.text("Todo:")]),
    //
    keyed.ul([attribute.class("flex flex-col gap-2")], {
      list.map(model.todos, fn(item) {
        let key = int.to_string(item.id)
        let html =
          html.li([], [
            // `UserToggledTodo` in a captured function,
            // which also returns a generic `msg` message
            // because `set_todos` returns `Effect(msg)`. ↓↓↓
            view_todo(item:, on_complete: UserToggledTodo(item.id, _)),
          ])

        #(key, html)
      })
    }),
    // 
    html.hr([]),
    view_input(on_submit: UserCreatedTodo),
    get_credits(),
  ])
}

fn view_todo(
  item item: Todo,
  on_complete handle_complete: fn(Bool) -> msg,
) -> Element(msg) {
  html.label([attribute.class("flex cursor-pointer items-center gap-2")], [
    html.p(
      [
        attribute.class("flex-1"),
        attribute.classes([#("line-through text-slate-400", item.completed)]),
      ],
      [html.text(item.title)],
    ),
    // https://stackoverflow.com/questions/72226003/how-to-change-the-background-color-of-unchecked-checkbox
    html.input([
      attribute.class("not-checked:appearance-none size-5 accent-green-500"),
      attribute.class("bg-neutral cursor-pointer"),
      attribute.class("rounded-md border border-slate-500"),
      attribute.type_("checkbox"),
      attribute.checked(item.completed),
      event.on_check(handle_complete),
    ]),
  ])
}

// This function returns an `Element(msg)` (with the generic argument `msg`),
// despite containing an `on_submit` event, because the handler function
// (`handle_submit`, which is the constructor of the `Msg` `UserCreatedTodo`
// type) when using the `set_todos` function that sets the ToDos in
// localstorage returns a generic effect (`Effect(msg)`).
fn view_input(
  on_submit handle_submit: fn(Result(String, Nil)) -> msg,
) -> Element(msg) {
  let on_submit =
    event.on_submit(fn(fields) {
      form.new({
        use title <- form.field(
          "title",
          form.parse_string
            |> form.map(string.trim)
            |> form.check_not_empty
            |> form.check_string_length_more_than(4),
        )
        form.success(title)
      })
      |> form.set_values(fields)
      |> form.run
      |> result.replace_error(Nil)
      |> handle_submit
    })

  html.form([attribute.id("new-todo"), on_submit], [
    html.label([attribute.for("title"), attribute.class("mb-2 block text-sm")], [
      html.text("What do you need to do?"),
    ]),
    html.div([attribute.class("flex items-center gap-2")], [
      html.input([
        attribute.class("flex-1 rounded border border-slate-300 px-2 py-1"),
        attribute.class("focus:border-blue-500 focus:outline-none"),
        attribute.id("title"),
        attribute.name("title"),
        attribute.required(True),
      ]),
      html.button([attribute.class("bg-primary rounded px-4 py-1")], [
        html.text("Add"),
      ]),
    ]),
  ])
}

fn get_credits() -> Element(msg) {
  html.a(
    [
      attribute.class(
        "absolute left-3 bottom-4 sm:bottom-6 text-center text-xs text-lime-500 hover:text-lime-300",
      ),
      attribute.href("https://github.com/emarifer?tab=repositories"),
      attribute.target("_blank"),
      attribute.rel("noopener noreferrer"),
    ],
    [
      html.text("⚡ Made by emarifer | Copyright © "),
      html.text(get_year()),
      html.text(" - MIT Licensed"),
    ],
  )
}

@external(javascript, "./todoapp_localstorage.ffi.mjs", "get_year")
fn get_year() -> String {
  ""
}
