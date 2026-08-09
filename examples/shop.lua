-- The consumer. Its existence is what keeps `Inventory.new` and `Inventory:add`
-- out of the report: analysis is whole-program, so a field defined in one file
-- and used only in another is live.

local Inventory = require('examples.inventory')

local function main()
  local stock = Inventory.new()
  stock:add('apple')
  stock:add('pear')
  return stock
end

print(main())
