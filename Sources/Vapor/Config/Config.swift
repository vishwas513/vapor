/**
    Parses and interprets configuration files
    included under Config in the working directory.

    Files stored in the Config directory can be accessed
    via `app.config.get("filename.property")`.

    For example, a file named `Config/app.json` containing
    `{"port": 80}` can be accessed with `app.config.get("app.port")`.
    To override certain configurations for a given environment,
    create a file with the same name in a subdirectory of the environment.
    For example, a file named `Config/production/app.json` would override
    any properties in `Config/app.json`. 

    Finally, Vapor supports sensitive environment specific information, such
    as API keys, to be stored in a special configuration file at `Config/.env.json`.
    This file should be included in the `.gitignore` by default so that
    sensitive information does not get added to version control.
*/

public class Config {
    //The internal store of configuration options
    //backed by `Json`
    private var repository: [String: Json]
    
    public enum Error: ErrorProtocol {
        case NoValueFound
    }

    /**
        Creates an instance of `Config` with an
        optional starting repository of information. 
        The application is required to detect environment.
    */
    public init(repository: [String: Json] = [:], application: Application? = nil) {
        self.repository = repository

        if let application = application {
            populate(application)
        }
    }

    ///Returns whether this instance of `Config` contains the key
    public func has(keyPath: String) -> Bool {
        let result: Json? = try? get(keyPath)
        return result != nil
    }
    
    ///Returns the generic Json representation for an item at a given path or throws
    public func get(keyPath: String) throws -> Json {
        var keys = keyPath.keys

        guard keys.count > 0 else {
            return nil
        }

        var value = repository[keys.removeFirst()]

        while value != nil && value != Json.NullValue && keys.count > 0 {
            value = value?[keys.removeFirst()]
        }

        guard let json = value else {
            throw Error.NoValueFound
        }
        
        return json
    }
    
    //Returns the value for a given type from the Config or throws
    public func get<T: JsonConvertible>(keyPath: String) throws -> T {
        let result: Json = try get(keyPath)
        return try T.makeWith(result)
    }
    

    ///Returns the result of `get(key: String)` but with a `String` fallback for `nil` cases
    public func get<T: JsonConvertible>(keyPath: String, _ fallback: T) -> T {
        let string: T? = try? get(keyPath)
        return string ?? fallback
    }

   
    ///Temporarily sets a value for a given key path
    public func set(value: Json, forKeyPath keyPath: String) {
        var keys = keyPath.keys
        let group = keys.removeFirst()

        if keys.count == 0 {
            repository[group] = value
        } else {
            repository[group]?.set(value, keys: keyPath.keys)
        }
    }

    ///Calls populate() in a convenient non-throwing manner
    public func populate(application: Application) -> Bool {
        let configDir = application.workDir + "Config"

        if FileManager.fileAtPath(configDir).exists {
            do {
                try populate(configDir, application: application)
                return true
            } catch {
                Log.error("Unable to populate config: \(error)")
                return false
            }
        } else {
            return false
        }
    }

    ///Attempts to populate the internal configuration store
    public func populate(path: String, application: Application) throws {
        var path = path.finish("/")
        var files = [String: [String]]()

        // Populate config files by environment
        try populateConfigFiles(&files, in: path)

        for env in application.environment.description.keys {
            path += env + "/"

            if FileManager.fileAtPath(path).exists {
                try populateConfigFiles(&files, in: path)
            }
        }

        // Loop through files and merge config upwards so the
        // environment always overrides the base config
        for (group, files) in files {
            if group == ".env" {
                // .env is handled differently below
                continue
            }

            for file in files {
                let data = try FileManager.readBytesFromFile(file)
                let json = try Json.deserialize(data)

                if repository[group] == nil {
                    repository[group] = json
                } else {
                    repository[group]?.merge(with: json)
                }
            }
        }

        // Apply .env overrides, which is a single file
        // containing multiple groups
        if let env = files[".env"] {
            for file in env {
                let data = try FileManager.readBytesFromFile(file)
                let json = try Json.deserialize(data)

                guard case let .ObjectValue(object) = json else {
                    return
                }

                for (group, json) in object {
                    if repository[group] == nil {
                        repository[group] = json
                    } else {
                        repository[group]?.merge(with: json)
                    }
                }
            }
        }
    }

    #if swift(>=3.0)
    private func populateConfigFiles(files: inout [String: [String]], in path: String) throws {
        let contents = try FileManager.contentsOfDirectory(path)
        let suffix = ".json"

        for file in contents {
            #if os(Linux)
                guard let fileName = file.split("/").last, suffixRange = fileName.rangeOfString(suffix) where suffixRange.endIndex == fileName.characters.endIndex else {
                    continue
                }
                
                let name = fileName.substringToIndex(suffixRange.startIndex)
            #else
                guard let fileName = file.split("/").last, suffixRange = fileName.range(of: suffix) where suffixRange.endIndex == fileName.characters.endIndex else {
                    continue
                }
                
                let name = fileName.substring(to: suffixRange.startIndex)
            #endif


            if files[name] == nil {
                files[name] = []
            }

            files[name]?.append(file)
        }
    }
    #else
    private func populateConfigFiles(inout files: [String: [String]], in path: String) throws {
        let contents = try FileManager.contentsOfDirectory(path)

        for file in contents {
            guard let fileName = file.split("/").last else {
                continue
            }

            let name: String

            if (fileName == ".env.json") {
                name = ".env"
            } else if fileName.hasSuffix(".json"), let value = fileName.split(".").first {
                name = value
            } else {
                continue
            }

            if files[name] == nil {
                files[name] = []
            }

            files[name]?.append(file)
        }
    }
    #endif

}

extension Json {

    mutating private func set(value: Json, keys: [String]) {
        var keys = keys

        guard keys.count > 0 else {
            return
        }

        let key = keys.removeFirst()

        guard case let .ObjectValue(object) = self else {
            return
        }

        var updated = object

        if keys.count == 0 {
            updated[key] = value
        } else {
            var child = updated[key] ?? Json.ObjectValue([:])
            child.set(value, keys: keys)
        }

        self = .ObjectValue(updated)
    }

}

extension String {

    private var keys: [String] {
        return split(".")
    }

}
