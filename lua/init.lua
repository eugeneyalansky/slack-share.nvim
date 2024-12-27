local pickers = require 'telescope.pickers'
local finders = require 'telescope.finders'
local actions = require 'telescope.actions'
local action_state = require 'telescope.actions.state'
local conf = require('telescope.config').values
local curl = require 'plenary.curl'
local fidget = require 'fidget'

--- @class slack_share.User
--- @field id string: User id
--- @field team string: team id
--- @field name string: User real name

local Slack = {
	base_url = 'https://slack.com/api/',
	cache_file = vim.fn.stdpath 'cache' .. '/slack_users_cache.json',
}

function Slack.new()
	local slack_token = os.getenv 'SLACK_TOKEN'
	if not slack_token or slack_token == '' then
		error 'Error: SLACK_TOKEN is missing. Please set it as an environment variable.'
	end
	local self = setmetatable({}, { __index = Slack }) -- Set self to inherit from Slack
	self._token = slack_token
	return self
end

---@return slack_share.User[]: list of users
function Slack:fetch_users()
	fidget.notify 'Fetching users...'

	local result, err = curl.get(self.base_url .. 'users.list', {
		headers = {
			['Content-Type'] = 'application/json',
			['Authorization'] = 'Bearer ' .. self._token,
		},
	})

	if err then
		error('Slack API Error: ' .. err)
	end
	local data = vim.fn.json_decode(result.body)
	if not data.ok then
		error('Slack API Error: ' .. (data.error or 'Unknown error'))
	end

	local users = {}
	for _, user in ipairs(data.members) do
		if not user.deleted then
			table.insert(users, { id = user.id, team = user.team_id, name = user.profile.real_name })
		end
	end
	fidget.notify 'Fetched'

	return users
end

---@class slack_share.GetUserOptions
---@field force_update boolean|nil: Force update the cache
---@field as_hashmap boolean|nil: Return results as a table of users

---@param opts slack_share.GetUserOptions: options
---@return slack_share.User[]: Get users from cache if exists, else directly from api
function Slack:get_users(opts)
	local o = opts or {
		force_update = false,
		as_hashmap = false,
	}
	local users = self:_get_users_from_cache()
	if not users or o.force_update then
		users = self:fetch_users()
		self:_save_users_to_cache(users)
	end
	if o.as_hashmap then
		local result = {}
		for _, user in ipairs(users) do
			result[user.name] = user
		end
		return result
	end
	return users
end

function Slack:post_message(content, channel_id)
	local payload = {
		channel = channel_id,
		blocks = {
			{
				type = 'section',
				text = { type = 'mrkdwn', text = '```\n' .. content .. '```' },
			},
			{
				type = 'context',
				elements = { { type = 'mrkdwn', text = 'Shared with *IDEShare*' } },
			},
		},
	}
	local response = curl.post(self.base_url .. 'chat.postMessage', {
		body = vim.fn.json_encode(payload),
		headers = {
			['Content-Type'] = 'application/json',
			['Authorization'] = 'Bearer ' .. self._token,
		},
	})
	if response.status == 200 then
		fidget.notify 'Message Sent'
	else
		fidget.notify('Some error during sending the message', vim.log.levels.ERROR)
	end
end

--- @param users slack_share.User[]:
--- @return nil: Just saving to cache
function Slack:_save_users_to_cache(users)
	local file = io.open(self.cache_file, 'w')
	if not file then
		error 'Unable to open cache file for writing.'
	end
	file:write(vim.fn.json_encode(users))
	file:close()
end

--- @return nil | slack_share.User[]: Retrieving from cache
function Slack:_get_users_from_cache()
	local file = io.open(self.cache_file, 'r')
	if not file then
		fidget.notify 'no cache file found'
		return nil
	end

	local cached_data = file:read '*a'
	file:close()

	if cached_data and cached_data ~= '' then
		return vim.fn.json_decode(cached_data)
	else
		fidget.notify 'cache file is empty'
		return nil
	end
end

---@return nil
function Slack:clear_cache()
	os.remove(self.cache_file)
end

--- @return boolean: If current editor in visual mode or not.
local in_visual_mode = function()
	local mode = vim.fn.mode()
	if mode == 'v' or mode == 'V' or mode == '' then
		return true
	end
	return false
end

--- @return string: Return the selected text if editor in selection mode
local get_selection_text = function()
	if in_visual_mode == false then
		return ''
	end

	local vstart = vim.fn.getpos "'<"
	local vend = vim.fn.getpos "'>"
	local line_start = vstart[2]
	local line_end = vend[2]
	local lines = vim.fn.getline(line_start, line_end)

	local result = ''

	for _, line in ipairs(lines) do
		result = result .. line .. '\n'
	end
	return result
end

---@class slack_share.PickChannelAction
---@field selection slack_share.User[]: Users to select from
---@field func function: Function to execute, takes User as an argument
---@field description string: Telescope description

---@param opts slack_share.PickChannelAction: function options
local pick_channel = function(opts)
	pickers
		.new({}, {
			prompt_title = opts.description or 'Select channel',
			finder = finders.new_table {
				results = opts.selection,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.name,
						ordinal = entry.name,
					}
				end,
			},
			sorter = conf.generic_sorter {},
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selected = action_state.get_selected_entry()
					if selected then
						opts.func(selected.value)
					end
				end)
				return true
			end,
		})
		:find()
end

local M = {}

function M.setup(opts)
	opts = opts or {
		no_cache = false,
	}
	local slack = Slack.new()

	vim.api.nvim_create_user_command('SlackShare', function()
		local message = get_selection_text()
		if message == '' then
			fidget.notify('Cannot SlackShare the empty selection', vim.log.levels.WARN)
			return
		end

		pick_channel {
			selection = slack:get_users(opts.no_cache),
			func = function(channel)
				slack:post_message(message, channel.id)
			end,
			description = 'Select Slack Channel to share snippet',
		}
	end, { range = true, desc = 'Share selected text to slack' })

	vim.api.nvim_create_user_command('SlackWith', function()
		pick_channel {
			selection = slack:get_users(opts.no_cache),
			description = 'Slack with makernaught',
			func = function(channel)
				local slack_url = 'slack://user?team=' .. channel.team .. '&id=' .. channel.id
				vim.fn.system('open ' .. "'" .. slack_url .. "'")
			end,
		}
	end, {
		desc = 'Share selected text to slack',
	})

	vim.api.nvim_create_user_command('SlackXCacheUpdate', function()
		local users = slack:get_users { force_update = true }
		print('Saved ' .. #users .. ' channels')
	end, { desc = 'Update cached channels list' })

	vim.api.nvim_create_user_command('SlackXCacheClear', function()
		slack:clear_cache()
	end, { desc = 'Clear cache' })
end

return M
